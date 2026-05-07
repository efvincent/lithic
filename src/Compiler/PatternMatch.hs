-- | Phase-7 pattern coverage checks for case branches.
--
-- This module exposes a single entry point, 'checkCasePatterns', which reports:
--
-- 1. Non-exhaustive branch sets, with one synthesized witness pattern.
-- 2. Redundant (unreachable) branches in source order.
--
-- The implementation now uses explicit matrix machinery:
--
-- 1. A pattern matrix ('Matrix').
-- 2. Constructor specialization ('specialize').
-- 3. Default-column decomposition ('defaultMatrix').
--
-- Scope note:
--
-- 1. This is a Phase-7 implementation slice for case-branch coverage.
-- 2. It supports Bool and closed structural variants as finite constructor universes.
-- 3. Open/unknown universes require wildcard/default coverage.
module Compiler.PatternMatch
  ( CoverageError(..)
  , checkCasePatterns
  ) where

import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Compiler.AST
import Data.Generics.Labels ()
import GHC.Generics (Generic)

-- | Coverage failures reported by `checkCasePatterns`
data CoverageError
  = NonExhaustive [Pattern]
  | Redundant Pattern
  deriving (Show, Eq, Generic)

-- | Matrix occurence paths used by pattern-matrix algorithm
--
-- This is included as explicit Phase-7 structure so downstream diagnostics and
-- decision-tree work can attach witness/provenance paths without changing the
-- algorithm shape later
data Occurrence
  = Root
  | VariantPayload Occurrence Text
  | RecorField Occurrence Text
  deriving (Show, Eq, Generic)

-- | One row in the pattern matrix
type Row = [Pattern]

-- | Pattern matrix
type Matrix = [Row]

-- | Constructor heads used during specialization.
data Constructor
  = ConBool Bool
  | ConVariant Text Type
  | ConLit Literal
  deriving (Show, Eq, Generic)

-- | Constructor universe classification for the current head type.
data Universe
  = Finite [Constructor]
  | Open 
  deriving (Show, Eq, Generic)

-- | Check case-pattern coverage 
-- 
-- Reduncancy is enforced in source order for both finite and open universes.
-- Open universes rely on default / wildcard decomposition in usefull checks.
checkCasePatterns :: Type -> [Pattern] -> Either CoverageError ()
checkCasePatterns scrutTy pats = do
  let matrix = map (\p -> [p]) pats
  checkRedundant [scrutTy] [] pats
  case missingRow [scrutTy] matrix of
    Nothing -> Right ()
    Just witnessRow ->
      case witnessRow of
        (w:_) -> Left (NonExhaustive [w])
        []    -> Left (NonExhaustive [wildcardPat])

-- | Redundancy check in source order.
--
-- A branch is redundant if it is not useful relative to preceding rows.
checkRedundant :: [Type] -> [Pattern] -> [Pattern] -> Either CoverageError ()
checkRedundant _ _ [] = Right ()
checkRedundant tys prev (p : ps)
  | useful tys (map (\q -> [q]) prev) [p] = checkRedundant tys (prev ++ [p]) ps
  | otherwise = Left (Redundant p)

-- | Usefulness judgment for one query row against a matrix.
--
-- This follows Maranget-style decomposition over constructor specialization
-- and default projection, with one important refinement:
--
-- Variant heads are checked payload-aware so a prior clause like
-- @Ok "success"@ does not incorrectly make @Ok _@ unreachable.
useful :: [Type] -> Matrix -> Row -> Bool
useful tys matrix query =
  case (tys, query) of
    ([], []) ->
      null matrix

    (_ : _, []) ->
      False

    (ty : restTys, qHead : qTail)
      | isWild qHead ->
          case constructorUniverse ty of
            Finite ctors ->
              any
                (\ctor ->
                  useful
                    (constructorArgTypes ctor ++ restTys)
                    (specialize ctor matrix)
                    (replicate (constructorArity ctor) wildcardPat ++ qTail)
                )
                ctors
            Open ->
              useful restTys (defaultMatrix matrix) qTail

      -- Variant payload-aware usefulness:
      -- only rows with the same constructor label participate in payload checking.
      | PVariant _ label inner <- qHead ->
          case lookupKnownVariantPayloadType ty label of
            Just payloadTy ->
              let payloadMatrix = payloadMatrixForLabel label matrix
              in useful (payloadTy : restTys) payloadMatrix (inner : qTail)
            Nothing ->
              False

      | otherwise ->
          case queryConstructor ty qHead of
            Just (ctor, ctorQueryArgs) ->
              useful
                (constructorArgTypes ctor ++ restTys)
                (specialize ctor matrix)
                (ctorQueryArgs ++ qTail)
            Nothing ->
              False

    _ ->
      False

-- | Exhaustiveness judgement.
--
-- Returns:
--
-- 1. Nothing when exhaustive.
-- 2. One witness row when non-exhaustsive
missingRow  :: [Type] -> Matrix -> Maybe Row
missingRow tys matrix =
  case tys of
    [] ->
      if null matrix then Just [] else Nothing
    
    ty : restTys ->
      case constructorUniverse ty of
        Finite ctors ->
          firstJust (map tryCtor ctors)
          where
            tryCtor ctor = do
              let specialized = specialize ctor matrix
              witness <- missingRow (constructorArgTypes ctor ++ restTys) specialized
              let (ctorWitnessArgs, restWitness) =
                    splitAt (constructorArity ctor) witness
              pure (buildPattern ctor ctorWitnessArgs : restWitness)
        
        Open ->
          fmap (wildcardPat :) (missingRow restTys (defaultMatrix matrix))

-- | Constructor specialization: keep rows whose head can match the constructor,
-- replacing the head by constructor arguments
specialize :: Constructor -> Matrix -> Matrix
specialize ctor = mapMaybe (specializeRow ctor)

-- | Specialize one row by the selected constructor
specializeRow :: Constructor -> Row -> Maybe Row
specializeRow ctor = \case
  [] -> Nothing
  (p:rest) -> do
    args <- specializeHead ctor p
    pure (args ++ rest)

-- | Specialize one head pattern by constructor.
specializeHead :: Constructor -> Pattern -> Maybe [Pattern]
specializeHead ctor = \case
  p | isWild p -> Just (replicate (constructorArity ctor) wildcardPat)
  PLit _ (LBool b) ->
    case ctor of
      ConBool b' -> if b == b' then Just [] else Nothing
      ConLit lit' -> if lit' == LBool b then Just [] else Nothing
      _ -> Nothing
  PLit _ lit ->
    case ctor of
      ConLit lit' | lit == lit' -> Just []
      _ -> Nothing
  PVariant _ label inner ->
    case ctor of
      ConVariant label' _ | label == label' -> Just [inner]
      _ -> Nothing
  _ -> Nothing

-- | Default projection: keep only wildcard-capable rows and drop the head
defaultMatrix :: Matrix -> Matrix
defaultMatrix = mapMaybe defaultRow
  where 
    defaultRow = \case
      [] -> Nothing
      (p:rest) 
        | isWild p -> Just rest
        | otherwise -> Nothing

-- | Determine the constructor universe for the current head type
constructorUniverse :: Type -> Universe
constructorUniverse = \case
  TBool _ -> Finite [ConBool True, ConBool False]
  TVariant _ row -> 
    case rowFields row of
      Just fields -> Finite (map (\(l, ty) -> ConVariant l ty) fields)
      Nothing -> Open
  _ -> Open

-- | Extract row fields if and only if the row is structurally closed.
rowFields :: Type -> Maybe [(Text, Type)]
rowFields = \case
  TRowEmpty  _ -> Just []
  TRowExtend _ l ty rest -> ((l, ty) :) <$> rowFields rest
  _ -> Nothing

-- | Attempt to classify a concrete query head as a constructor application.
queryConstructor :: Type -> Pattern -> Maybe (Constructor, [Pattern])
queryConstructor ty pat =
  case pat of
    PLit _ (LBool b) -> Just (ConBool b, [])
    PLit _ lit | literalMatchesType ty lit -> Just (ConLit lit, [])
    PVariant _ label inner ->
      case lookupKnownVariantPayloadType ty label of
        Just payloadTy -> Just (ConVariant label payloadTy, [inner])
        Nothing -> Nothing
    _ -> Nothing

-- | Project matrix rows to payload/head-tail rows for one variant label.
--
-- For rows whose head is:
--
-- 1. A wildcard-like pattern: contribute a wildcard payload row.
-- 2. A matching variant constructor: contribute its payload row.
-- 3. Any other concrete head: excluded.
payloadMatrixForLabel :: Text -> Matrix -> Matrix
payloadMatrixForLabel targetLabel = mapMaybe project
  where
    project :: Row -> Maybe Row
    project = \case
      []                                                     -> Nothing
      (p:rest) | isWild p                                    -> Just (wildcardPat : rest)
      (PVariant _ label inner : rest) | label == targetLabel -> Just (inner : rest)
      _                                                      -> Nothing
        

-- | Lookup payload type for a variant label on a closed variant scrutinee type.
lookupKnownVariantPayloadType :: Type -> Text -> Maybe Type
lookupKnownVariantPayloadType ty targetLabel =
  case ty of
    TVariant _ row -> go row
    _ -> Nothing
  where
    go = \case
      TRowEmpty _ -> Nothing
      TRowExtend _ label payloadTy rest
        | label == targetLabel -> Just payloadTy
        | otherwise -> go rest
      _ -> Nothing

-- | Constructor arity.
constructorArity :: Constructor -> Int
constructorArity = \case
  ConBool _ -> 0
  ConVariant _ _ -> 1
  ConLit _ -> 0

-- | Constructor argument types
constructorArgTypes :: Constructor -> [Type]
constructorArgTypes = \case
  ConBool _ -> []
  ConVariant _ payloadTy -> [payloadTy]
  ConLit _ -> []

-- | Returns True when a literal head is type-compatible with the current
-- scrutinee head type for usefulness/specialization checks.
--
-- This is intentionally structural and local (head-level only):
-- it does not enumerate literal domains and does not depend on
-- operator capability/type-class resolution.
literalMatchesType :: Type -> Literal -> Bool
literalMatchesType ty lit =
  case (ty, lit) of
    (TBool _, LBool _) -> True
    (TString _, LString _) -> True
    (TInt _, LInt _) -> True
    (TFloat _, LFloat _) -> True
    _ -> False

-- | Rebuild a witness head pattern from the constructor plus witness args.
buildPattern :: Constructor -> [Pattern] -> Pattern
buildPattern ctor args =
  case ctor of
    ConLit lit         -> PLit dummySpan lit
    ConBool b          -> PLit dummySpan (LBool b)
    ConVariant label _ ->
      case args of 
        (p:_) -> PVariant dummySpan label p
        []    -> PVariant dummySpan label wildcardPat

-- | Return the first Just in a list, if any.
firstJust :: forall a. [Maybe a] -> Maybe a
firstJust = \case
  [] -> Nothing
  (x : xs) -> 
    case x of
      Just _ -> x
      Nothing -> firstJust xs

-- | Wildcard-like patterns
isWild :: Pattern -> Bool
isWild = \case
  PVar{} -> True
  PWildcard{} -> True
  _ -> False

-- | Canonical wildcard witness.
wildcardPat :: Pattern
wildcardPat = PWildcard dummySpan

-- | Placeholder span for synthesized witness patterns.
dummySpan :: SourceSpan
dummySpan = MkSourceSpan 0 0 0 0
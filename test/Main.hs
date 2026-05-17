module Main where

import Test.Tasty (defaultMain, testGroup)

import Test.Elaborator (elaboratorUnitTests)
import Test.Evaluator (evaluatorUnitTests)
import Test.Golden (discoverGoldenTests)
import Test.ParserDeclarations (parserDeclarationsUnitTests)
import Test.Phase9HScaffold (phase9HScaffoldUnitTests)
import Test.PatternCoverage (patternCoverageUnitTests)

main :: IO ()
main = do
  goldenTests <- discoverGoldenTests
  defaultMain $ testGroup "Lithic Compiler Tests"
    [ goldenTests
    , patternCoverageUnitTests
    , elaboratorUnitTests
    , evaluatorUnitTests
    , parserDeclarationsUnitTests
    , phase9HScaffoldUnitTests
    ]
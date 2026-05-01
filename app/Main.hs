module Main where

import Bluefin.Eff (runEff)
import Bluefin.IO (effIO)
import Bluefin.State (evalState)
import Brick.BChan (newBChan, writeBChan)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar)
import qualified Data.IntMap.Strict as IM

import Compiler.REPL (replLoop, runTerminalBrick)
import Compiler.TUI (runTUI, TUIEvent(..))
import Compiler.TypeChecker (TCState(..))

main :: IO ()
main = do
  eventChan <- newBChan 10
  inputMVar <- newEmptyMVar

  -- 1. Spin up the compiler REPL in a background thread
  _ <- forkIO $ runEff \io -> do
    
    -- Allocate the state handler FIRST
    evalState (MkTCState 0 IM.empty) \st -> do
      
      -- Now create the terminal handle INSIDE the state's effect stack
      let term = runTerminalBrick eventChan inputMVar io
      
      -- Both handles now perfectly share the same effect stack
      replLoop term st
      
    -- When the REPL loop naturally exits (e.g., via ":quit"), tell Brick to halt
    effIO io $ writeBChan eventChan TUIQuit

  -- 2. Take over the main thread with the Brick UI
  runTUI eventChan inputMVar
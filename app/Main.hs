module Main where

import Bluefin.Eff (runEff)
import Bluefin.IO (effIO)
import Brick.BChan (newBChan, writeBChan)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar)
import Compiler.REPL (replLoop, runTerminalBrick)
import Compiler.TUI (runTUI, TUIEvent(..))

main :: IO ()
main = do
  eventChan <- newBChan 10
  inputMVar <- newEmptyMVar

  -- 1. Spin up the compiler REPL in a background thread
  _ <- forkIO $ runEff \io -> do
    let term = runTerminalBrick eventChan inputMVar io
    replLoop term
    -- When the REPL loop naturally exits (e.g., via ":quit"), tell Brick to halt
    effIO io $ writeBChan eventChan TUIQuit

  -- 2. Take over the main thread with the Brick UI
  runTUI eventChan inputMVar


-- module Main where

-- import Bluefin.Eff (runEff)
-- import Compiler.REPL (replLoop, runTerminalIO)

-- main :: IO ()
-- main = runEff \io -> do
--   let term = runTerminalIO io
--   replLoop term

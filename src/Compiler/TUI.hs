module Compiler.TUI where

import Brick
import Brick.BChan (BChan)
import Brick.Widgets.Edit (Editor, editor, handleEditorEvent, getEditContents, renderEditor)
import Control.Concurrent.MVar (MVar, tryPutMVar)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Function ((&))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Data.Generics.Labels ()
import Graphics.Vty (Event(..), Key(..), Modifier(..))
import qualified Graphics.Vty.CrossPlatform as Vty
import Lens.Micro ((.~), (%~))
import qualified Graphics.Vty as Vty

-- | Custom events sent from the Bluefin REPL thread to the Brick UI thread
data TUIEvent
  = TUIOutput Text
  | TUIPrompt Text
  | TUIQuit

-- | Unique identifiers for stateful Brick widgets
data WidgetName = LogViewport | PromptEditor
  deriving (Eq, Ord, Show, Generic)

-- | The UI State
data AppState = MkAppState
  { logLines :: ![Text]
  , promptInput :: !(Editor Text WidgetName)
  , currentPrompt :: !Text
  } deriving (Generic)

-- | Draws the scrollback log above the active log
drawUI :: AppState -> [Widget WidgetName]
drawUI st = [ui]
  where
    logWidget = viewport LogViewport Vertical . vBox $ map txtWrap st.logLines
    promptWidget = txt st.currentPrompt <+> renderEditor (txt . T.unlines) True st.promptInput
    ui = vBox [logWidget, fill ' ', promptWidget]

-- | Handles keypresses and messages from the REPL
handleEvent :: MVar (Maybe Text) -> BrickEvent WidgetName TUIEvent -> EventM WidgetName AppState ()
handleEvent inputMVar = \case
  -- Ctrl-C to quit globally
  VtyEvent (EvKey (KChar 'c') [MCtrl]) -> do
    liftIO $ void $ tryPutMVar inputMVar Nothing
    halt

  -- Enter key submits the code to the REPL
  VtyEvent (EvKey KEnter []) -> do
    st <- get
    let content = T.concat (getEditContents st.promptInput)
    -- clear the editor and echo the input to the log
    put $ st & #promptInput .~ editor PromptEditor (Just 1) ""
             & #logLines %~ (<> [st.currentPrompt <> content])

    liftIO $ void $ tryPutMVar inputMVar (Just content)
    -- Auto-scroll down after echoing the viewport
    vScrollToEnd (viewportScroll LogViewport)

  -- Messages from the Bluefin REPL thread
  AppEvent (TUIOutput msg) -> do
    -- Safely split by newlines just in case, then append
    modify \s -> s & #logLines %~ (<> T.lines msg)
    -- Auto-scroll down to reveal the newly printed tokens
    vScrollToEnd (viewportScroll LogViewport) 
  
  AppEvent (TUIPrompt p) -> do
    modify \s -> s & #currentPrompt .~ p
    vScrollToEnd (viewportScroll LogViewport) 

  AppEvent TUIQuit -> halt

  -- Pass all other keystrokes to the text editor widget
  ev -> zoom #promptInput $ handleEditorEvent ev

-- | Bootstrap the Brick application
runTUI :: BChan TUIEvent -> MVar (Maybe Text) -> IO ()
runTUI eventChan inputMVar = do
-- 1. The evaluated handle to start the UI immediately
  initialVty <- Vty.mkVty Vty.defaultConfig
  
  -- 2. The blueprint action so Brick can rebuild the UI if suspended
  let buildVty = Vty.mkVty Vty.defaultConfig
  let app = App
        { appDraw = drawUI
        , appChooseCursor = showFirstCursor
        , appHandleEvent = handleEvent inputMVar
        , appStartEvent = pure ()
        , appAttrMap = const $ attrMap Vty.defAttr []
        }
  let initialState = MkAppState [] (editor PromptEditor (Just 1) "") ""
  _ <- customMain initialVty buildVty (Just eventChan) app initialState
  pure ()
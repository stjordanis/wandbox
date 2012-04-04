module Handler.Compile (
  getSourceR,
  postCompileR
) where

import Import
import Network.Wai.EventSource (ServerEvent(..), eventSourceAppChan)
import Control.Concurrent (forkIO)
import Blaze.ByteString.Builder.ByteString (fromByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.Text as T
import qualified ChanMap as CM
import Control.Exception (bracket)
import System.IO (hClose, hFlush)
import Codec.Binary.Url (encode)
import Data.Text.Encoding (encodeUtf8)

import qualified Data.Conduit as C
import Data.Conduit (($$))
import qualified Data.Conduit.List as CL

import VM.Protocol (Protocol(..), ProtocolSpecifier(..))
import VM.Conduit (connectVM, sendVM, receiveVM)

getSourceR :: Text -> Handler ()
getSourceR ident = do
    cm <- getChanMap <$> getYesod
    chan <- liftIO $ CM.insertLookup cm ident

    req <- waiRequest
    res <- lift $ eventSourceAppChan chan req

    sendWaiResponse res

vmHandle :: T.Text -> C.Sink (Either String Protocol) IO () -> IO ()
vmHandle code sink =
  bracket connectVM hClose $ \handle -> do
    C.runResourceT $ CL.sourceList protos $$ sendVM handle
    hFlush handle
    C.runResourceT $ receiveVM handle $$ sink
  where
    protos = [Protocol Control "compiler=g++",
              Protocol CompilerOption "<optimize>2",
              Protocol Source code,
              Protocol Control "run"]

urlEncode :: ProtocolSpecifier -> T.Text -> B.ByteString
urlEncode spec contents = B.concat [BC.pack $ show spec, ":", BC.pack $ encode $ B.unpack $ encodeUtf8 contents]

sinkProtocol :: (ServerEvent -> IO ()) -> C.Sink (Either String Protocol) IO ()
sinkProtocol writeChan = C.sinkState () push close
  where
    push _ (Left str) = do liftIO $ putStrLn str
                           return $ C.StateDone Nothing ()
    push _ (Right ProtocolNil) = do liftIO $ print ProtocolNil
                                    return $ C.StateDone Nothing ()
    push _ (Right (Protocol spec contents)) = do
      liftIO $ writeChan $ ServerEvent Nothing Nothing [fromByteString $ urlEncode spec contents]
      return $ C.StateProcessing ()
    close _ = return ()

postCompileR :: Text -> Handler ()
postCompileR ident = do
  mCode <- lookupPostParam "code"
  maybe (return ()) go mCode
  where
    go code = do
      cm <- getChanMap <$> getYesod
      _ <- liftIO $ forkIO $ vmHandle code $ sinkProtocol $ CM.writeChan cm ident
      return ()

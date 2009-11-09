{-# LANGUAGE StandaloneDeriving, TypeSynonymInstances, UndecidableInstances, OverlappingInstances, IncoherentInstances #-}
module Network.Salvia.Impl.Handler where

import Control.Applicative
import Control.Concurrent.STM
import Control.Monad.State
import Prelude hiding (mod)
import Data.Monoid
import Data.Record.Label hiding (get)
import qualified Data.Record.Label as L
import Network.Protocol.Http
import Network.Salvia.Core.Config
import Network.Salvia.Core.Context
import Network.Salvia.Handler.Body
import Network.Salvia.Handler.Printer
import Network.Salvia.Handler.Session
import Network.Salvia.Handler.Login
import Safe
import System.IO
import Network.Salvia.Core.Aspects
import qualified Data.ByteString as ByteString

newtype Handler c p a = Handler { unHandler :: StateT (Context c p) IO a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadState (Context c p))

runHandler :: Handler c p a -> Context c p -> IO (a, Context c p)
runHandler h = runStateT (unHandler h)

type ServerHandler p a = Handler Config p a
type ClientHandler   a = Handler () () a

instance HttpM Request (Handler c p) where
  http st =
    do (a, s) <- runState st <$> getM cRequest
       cRequest =: s >> return a

instance HttpM Response (Handler c p) where
  http st =
    do (a, s) <- runState st <$> getM cResponse
       cResponse =: s >> return a

instance QueueM (Handler c p) where
  enqueue f     = modM cQueue (++[f])
  dequeue       = headMay <$> getM cQueue <* modM cQueue (tailDef [])

instance SendM (Handler c p) where
  send        s    = enqueue (flip hPutStr s . snd)
  sendBs      bs   = enqueue (flip ByteString.hPutStr bs . snd)
  spoolWith   f fd = enqueue (\(_, h) -> hGetContents fd >>= hPutStr h . f)
  spoolWithBs f fd = enqueue (\(_, h) -> ByteString.hGetContents fd >>= ByteString.hPut h . f)

instance SockM (Handler c p) where
  rawSock = getM cRawSock
  sock    = getM cSock

instance ClientAddressM (Handler c p) where
  clientAddress = getM cClientAddr

instance ServerAddressM (Handler c p) where
  serverAddress = getM cServerAddr

instance Monoid a => Monoid (Handler c p a) where
  mempty  = mzero >> return mempty
  mappend = mplus

instance Alternative (Handler c p) where
  empty = mzero
  (<|>) = mplus

instance MonadPlus (Handler c p) where
  mzero =
    do http (status =: BadRequest)
       return (error "mzero/empty")
  a `mplus` b =
    do r <- a
       s <- http (getM status)
       if statusFailure s
         then http (put emptyResponse) >> mzero >> b
         else return r

instance FlushM Response (Handler c p) where
  flushHeaders = hFlushHeaders
  flushQueue _ = hFlushQueue

instance FlushM Request (Handler c p) where
  flushHeaders = hFlushHeaders
  flushQueue _ = hFlushQueue

instance BodyM Request (Handler c p) where
  body = hRawBody

instance BodyM Response (Handler c p) where
  body = hRawBody

instance ServerM (Handler Config p) where
  server = getM cConfig

instance ClientM (Handler () ()) where
  client = return ()

instance Contains p (TVar q) => PayloadM (Handler c p) p q where
  payload st =
    do pl <- getM cPayload :: Handler c p p
       let var = L.get select pl :: TVar q
       liftIO . atomically $
          do q <- readTVar var
             let (s, q') = runState st q
             writeTVar var q'
             return s

instance Contains q (TVar (Sessions p))
      => SessionM (Handler Config q) p where
  prolongSession = hProlongSession (undefined :: p)
  getSession     = hGetSession
  putSession     = hPutSession
  delSession     = hDelSession     (undefined :: p)
  withSession    = hWithSession

instance ( Contains q (TVar (Sessions (UserPayload p)))
         , Contains q (TVar UserDatabase)
         ) => LoginM (Handler Config q) p where
  login      = hLogin      (undefined :: p)
  logout     = hLogout     (undefined :: p)
  signup     = hSignup     (undefined :: p)
  authorized = hAuthorized (undefined :: p)


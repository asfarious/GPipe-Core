{-# LANGUAGE RankNTypes, GeneralizedNewtypeDeriving, FlexibleContexts, FlexibleInstances, GADTs, DeriveDataTypeable #-}

module Graphics.GPipe.Internal.Context 
(
    ContextFactory,
    ContextHandle(..),
    ContextT(),
    GPipeException(..),
    runContextT,
    runSharedContextT,
    liftContextIO,
    liftContextIOAsync,
    addContextFinalizer,
    getContextFinalizerAdder,
    getRenderContextFinalizerAdder ,
    swapContextBuffers,
    withContextWindow,
    addVAOBufferFinalizer,
    addFBOTextureFinalizer,
    getContextData,
    getRenderContextData,
    getVAO, setVAO,
    getFBO, setFBO,
    ContextData,
    VAOKey(..), FBOKey(..), FBOKeys(..),
    Render(..), render, getContextBuffersSize
)
where

import Graphics.GPipe.Internal.Format
import Control.Monad.Exception (MonadException, Exception, MonadAsyncException,bracket)
import Control.Monad.Trans.Reader 
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Applicative (Applicative, (<$>))
import Data.Typeable (Typeable)
import qualified Data.Map.Strict as Map 
import Graphics.GL.Core33
import Graphics.GL.Types
import Control.Concurrent.MVar
import Data.IORef
import Control.Monad
import Data.List (delete)
import Foreign.C.Types
import Data.Maybe (maybeToList)
import Linear.V2 (V2(V2))

type ContextFactory c ds w = ContextFormat c ds -> IO (ContextHandle w)

data ContextHandle w = ContextHandle {
    -- | Like a 'ContextFactory' but creates a context that shares the object space of this handle's context  
    newSharedContext :: forall c ds. ContextFormat c ds -> IO (ContextHandle w),
    -- | Run an OpenGL IO action in this context, returning a value to the caller. The thread calling this may not be the same creating the context. 
    contextDoSync :: forall a. IO a -> IO a,
    -- | Run an OpenGL IO action in this context, that doesn't return any value to the caller. The thread calling this may not be the same creating the context (for finalizers it is most definetly not).
    contextDoAsync :: IO () -> IO (),
    -- | Swap the front and back buffers in the context's default frame buffer. This will be called as an argument to 'contextDoSync' so you can assume it is run on the right GL thread. 
    contextSwap :: IO (),   
    -- | Get the current size of the context's default framebuffer (which may change if the window is resized). This will be called as an argument to 'contextDoSync' so you can assume it is run on the right GL thread. 
    contextFrameBufferSize :: IO (Int, Int),
    -- | Delete this context and close any associated window. The thread calling this may not be the same creating the context.  
    contextDelete :: IO (),
    -- | A value representing the context's window. It is recommended that this is an opaque type that doesn't have any exported functions. Instead, provide 'ContextT' actions 
    --   that are implemented in terms of 'withContextWindow' to expose any functionality to the user that need a reference the context's window.
    contextWindow :: w
} 

-- | The monad transformer that encapsulates a GPipe context (which wraps an OpenGl context).
--
--   A value of type @ContextT w os f m a@ is an action on a context with these parameters:
--
--   [@w@] The type of the window that is bound to this context. It is defined by the window manager package and is probably an opaque type.
--
--   [@os@] An abstract type that is used to denote the object space. This is an forall type defined by the 'runContextT' call which will restrict any objects created inside this context 
--          to be returned from it or used by another context (the same trick as the 'ST' monad uses).
--
--   [@f@] The format of the context's default frame buffer, always an instance of 'ContextFormat'.
--
--   [@m@] The monad this monad transformer wraps. Need to have 'IO' in the bottom for this 'ContextT' to be runnable.
--
--   [@a@] The value returned from this monad action. 
--
newtype ContextT w os f m a = 
    ContextT (ReaderT (ContextHandle w, (ContextData, SharedContextDatas)) m a) 
    deriving (Functor, Applicative, Monad, MonadIO, MonadException, MonadAsyncException)
    
instance MonadTrans (ContextT w os f) where
    lift = ContextT . lift 

-- | Run a 'ContextT' monad transformer, creating a window (unless the 'ContextFormat' is 'ContextFormatNone') that is later destroyed when the action returns. This function will
--   also create a new object space. 
--   You need a 'ContextFactory', which is provided by an auxillary package, such as @GPipe-GLFW@.
runContextT :: (MonadIO m, MonadAsyncException m) => ContextFactory c ds w -> ContextFormat c ds -> (forall os. ContextT w os (ContextFormat c ds) m a) -> m a
runContextT cf f (ContextT m) = 
    bracket 
        (liftIO $ cf f)
        (liftIO . contextDelete)
        $ \ h -> do cds <- liftIO newContextDatas
                    cd <- liftIO $ addContextData cds
                    let ContextT i = initGlState
                        rs = (h, (cd, cds))
                    runReaderT (i >> m) rs

-- | Run a 'ContextT' monad transformer inside another one, creating a window (unless the 'ContextFormat' is 'ContextFormatNone') that is later destroyed when the action returns. The inner 'ContextT' monad
-- transformer will share object space with the outer one. The 'ContextFactory' of the outer context will be used in the creation of the inner context. 
runSharedContextT :: (MonadIO m, MonadAsyncException m) => ContextFormat c ds -> ContextT w os (ContextFormat c ds) (ContextT w os f m) a -> ContextT w os f m a
runSharedContextT f (ContextT m) =
    bracket
        (do (h',(_,cds)) <- ContextT ask
            h <- liftIO $ newSharedContext h' f
            cd <- liftIO $ addContextData cds
            return (h,cd)
        )
        (\(h,cd) -> do cds <- ContextT $ asks (snd . snd)
                       liftIO $ removeContextData cds cd
                       liftIO $ contextDelete h)
        $ \(h,cd) -> do cds <- ContextT $ asks (snd . snd)
                        let ContextT i = initGlState
                            rs = (h, (cd, cds))
                        runReaderT (i >> m) rs

initGlState :: MonadIO m => ContextT w os f m ()
initGlState = liftContextIOAsync $ do glEnable GL_FRAMEBUFFER_SRGB
                                      glEnable GL_SCISSOR_TEST
                                      glPixelStorei GL_PACK_ALIGNMENT 1
                                      glPixelStorei GL_UNPACK_ALIGNMENT 1

liftContextIO :: MonadIO m => IO a -> ContextT w os f m a
liftContextIO m = ContextT (asks fst) >>= liftIO . flip contextDoSync m

addContextFinalizer :: MonadIO m => IORef a -> IO () -> ContextT w os f m ()
addContextFinalizer k m = ContextT (asks fst) >>= liftIO . void . mkWeakIORef k . flip contextDoAsync m

getContextFinalizerAdder  :: MonadIO m =>  ContextT w os f m (IORef a -> IO () -> IO ())
getContextFinalizerAdder = do h <- ContextT (asks fst)
                              return $ \k m -> void $ mkWeakIORef k (contextDoAsync h m)  

liftContextIOAsync :: MonadIO m => IO () -> ContextT w os f m ()
liftContextIOAsync m = ContextT (asks fst) >>= liftIO . flip contextDoAsync m

-- | Run this action after a 'render' call to swap out the context windows back buffer with the front buffer, effectively showing the result.
--   This call may block if vsync is enabled in the system and/or too many frames are outstanding.
--   After this call, the context window content is undefined and should be cleared at earliest convenience using 'clearContextColor' and friends.
swapContextBuffers :: MonadIO m => ContextT w os f m ()
swapContextBuffers = ContextT (asks fst) >>= (\c -> liftIO $ contextDoSync c $ contextSwap c)

type ContextDoAsync = IO () -> IO ()

-- | A monad in which shaders are run.
newtype Render os f a = Render (ReaderT (ContextDoAsync, (ContextData, SharedContextDatas)) IO a) deriving (Monad, Applicative, Functor)

-- | Run a 'Render' monad, that may have the effect of the context window or textures being drawn to.   
render :: (MonadIO m, MonadException m) => Render os f () -> ContextT w os f m ()
render (Render m) = ContextT ask >>= (\c -> let doAsync = contextDoAsync (fst c) in liftIO $ doAsync $ runReaderT m (doAsync, snd c))

-- | Return the current size of the context frame buffer. This is needed to set viewport size and to get the aspect ratio to calculate projection matrices.  
getContextBuffersSize :: MonadIO m => ContextT w os f m (V2 Int)
getContextBuffersSize = ContextT $ do c <- asks fst
                                      (x,y) <- liftIO $ contextDoSync c $ contextFrameBufferSize c
                                      return $ V2 x y

-- | Use the context window handle, which type is specific to the window system used. This handle shouldn't be returned from this function
withContextWindow :: MonadIO m => (w -> IO a) -> ContextT w os f m a
withContextWindow f= ContextT $ do c <- asks fst
                                   liftIO $ contextDoSync c $ f (contextWindow c)

getRenderContextFinalizerAdder  :: Render os f (IORef a -> IO () -> IO ())
getRenderContextFinalizerAdder = do f <- Render (asks fst)
                                    return $ \k m -> void $ mkWeakIORef k (f m)  

-- | This kind of exception may be thrown from GPipe when a GPU hardware limit is reached (for instance, too many textures are drawn to from the same 'FragmentStream') 
data GPipeException = GPipeException String
     deriving (Show, Typeable)

instance Exception GPipeException


-- TODO Add async rules     
{-# RULES
"liftContextIO >>= liftContextIO >>= x"    forall m1 m2 x.  liftContextIO m1 >>= (\_ -> liftContextIO m2 >>= x) = liftContextIO (m1 >> m2) >>= x
"liftContextIO >>= liftContextIO"          forall m1 m2.    liftContextIO m1 >>= (\_ -> liftContextIO m2) = liftContextIO (m1 >> m2)
  #-}

--------------------------

type SharedContextDatas = MVar [ContextData]
type ContextData = MVar (VAOCache, FBOCache)
data VAOKey = VAOKey { vaoBname :: !GLuint, vaoCombBufferOffset :: !Int, vaoComponents :: !GLint, vaoNorm :: !Bool, vaoDiv :: !Int } deriving (Eq, Ord)
data FBOKey = FBOKey { fboTname :: !GLuint, fboTlayerOrNegIfRendBuff :: !Int, fboTlevel :: !Int } deriving (Eq, Ord)
data FBOKeys = FBOKeys { fboColors :: [FBOKey], fboDepth :: Maybe FBOKey, fboStencil :: Maybe FBOKey } deriving (Eq, Ord)  
type VAOCache = Map.Map [VAOKey] (IORef GLuint)
type FBOCache = Map.Map FBOKeys (IORef GLuint)

getFBOKeys :: FBOKeys -> [FBOKey]
getFBOKeys (FBOKeys xs d s) = xs ++ maybeToList d ++ maybeToList s

newContextDatas :: IO (MVar [ContextData])
newContextDatas = newMVar []

addContextData :: SharedContextDatas -> IO ContextData
addContextData r = do cd <- newMVar (Map.empty, Map.empty)  
                      modifyMVar_ r $ return . (cd:)
                      return cd

removeContextData :: SharedContextDatas -> ContextData -> IO ()
removeContextData r cd = modifyMVar_ r $ return . delete cd

addCacheFinalizer :: MonadIO m => (GLuint -> (VAOCache, FBOCache) -> (VAOCache, FBOCache)) -> IORef GLuint -> ContextT w os f m ()
addCacheFinalizer f r =  ContextT $ do cds <- asks (snd . snd)
                                       liftIO $ do n <- readIORef r
                                                   void $ mkWeakIORef r $ do cs' <- readMVar cds 
                                                                             mapM_ (`modifyMVar_` (return . f n)) cs'

addVAOBufferFinalizer :: MonadIO m => IORef GLuint -> ContextT w os f m ()
addVAOBufferFinalizer = addCacheFinalizer deleteVAOBuf  
    where deleteVAOBuf n (vao, fbo) = (Map.filterWithKey (\k _ -> all ((/=n) . vaoBname) k) vao, fbo)

    
addFBOTextureFinalizer :: MonadIO m => Bool -> IORef GLuint -> ContextT w os f m ()
addFBOTextureFinalizer isRB = addCacheFinalizer deleteVBOBuf    
    where deleteVBOBuf n (vao, fbo) = (vao, Map.filterWithKey
                                          (\ k _ ->
                                             all
                                               (\ fk ->
                                                  fboTname fk /= n || isRB /= (fboTlayerOrNegIfRendBuff fk < 0))
                                               $ getFBOKeys k)
                                          fbo)


getContextData :: MonadIO m => ContextT w os f m ContextData
getContextData = ContextT $ asks (fst . snd)

getRenderContextData :: Render os f ContextData
getRenderContextData = Render $ asks (fst . snd)

getVAO :: ContextData -> [VAOKey] -> IO (Maybe (IORef GLuint))
getVAO cd k = do (vaos, _) <- readMVar cd
                 return (Map.lookup k vaos)    

setVAO :: ContextData -> [VAOKey] -> IORef GLuint -> IO ()
setVAO cd k v = modifyMVar_ cd $ \ (vaos, fbos) -> return (Map.insert k v vaos, fbos)  

getFBO :: ContextData -> FBOKeys -> IO (Maybe (IORef GLuint))
getFBO cd k = do (_, fbos) <- readMVar cd
                 return (Map.lookup k fbos)

setFBO :: ContextData -> FBOKeys -> IORef GLuint -> IO ()
setFBO cd k v = modifyMVar_ cd $ \(vaos, fbos) -> return (vaos, Map.insert k v fbos)  

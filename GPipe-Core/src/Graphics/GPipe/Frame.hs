{-# LANGUAGE MultiParamTypeClasses, TypeFamilies, FlexibleContexts,
  RankNTypes, ExistentialQuantification, GeneralizedNewtypeDeriving,
  FlexibleInstances, ImpredicativeTypes, GADTs #-}

module Graphics.GPipe.Frame (
    Frame(..),
    FrameM(..),
    FrameState(..),
    Render(..),
    getName,
    getDrawcall,
    tellDrawcall,
    modifyRenderIO,
    render,
    runFrame,
    compileFrame,
    mapFrame,
    guard',
    maybeFrame,
    chooseFrame,
    silenceFrame
) where


import Graphics.GPipe.FrameCompiler
import Graphics.GPipe.Context
import Control.Monad.Trans.State 
import Control.Monad.IO.Class

import Control.Monad.Trans.Writer.Lazy (tell, WriterT(..), runWriterT)
import Control.Monad.Exception (MonadException)
import Control.Applicative (Applicative, Alternative, (<|>))
import Control.Monad.Trans.Class (lift)
import Data.Maybe (fromJust, isJust)
import Control.Monad (MonadPlus)
import Control.Monad.Trans.List (ListT(..))
import Data.Monoid (All(..), mempty)
import Data.Either

data FrameState s = FrameState Int Int (RenderIOState s)

newFrameState :: FrameState s
newFrameState = FrameState 0 1 newRenderIOState

getName :: FrameM s Int
getName = do FrameState n d r <- FrameM $ lift $ lift get
             FrameM $ lift $ lift $ put $ FrameState (n+1) d r
             return n

getDrawcall :: FrameM s Int
getDrawcall = do FrameState n d r <- FrameM $ lift $ lift get
                 FrameM $ lift $ lift $ put $ FrameState n (d+1) r
                 return d

modifyRenderIO :: (RenderIOState s -> RenderIOState s) -> FrameM s ()
modifyRenderIO f = FrameM $ lift $ lift $ modify (\(FrameState a b s) -> FrameState a b (f s))

tellDrawcall :: IO (Drawcall s) -> FrameM s ()
tellDrawcall dc = FrameM $ tell ([dc], mempty) 

mapDrawcall :: (s -> s') -> Drawcall s' -> Drawcall s
mapDrawcall f (Drawcall b c d e g h i j k) = Drawcall (b . f) c d e g h i j k 
           
newtype FrameM s a = FrameM (WriterT ([IO (Drawcall s)], s -> All) (ListT (State (FrameState s))) a) deriving (MonadPlus, Monad, Alternative, Applicative, Functor)

newtype Frame os f s a = Frame (FrameM s a)  deriving (MonadPlus, Monad, Alternative, Applicative, Functor)

mapFrame :: (s -> s') -> Frame os f s' a -> Frame os f s a
mapFrame f (Frame (FrameM m)) = Frame $ FrameM $     
    do FrameState x y s <- lift $ lift get      
       let (adcs, FrameState x' y' s') = runState (runListT (runWriterT m)) (FrameState x y newRenderIOState)
       WriterT $ ListT $ do
            put $ FrameState x' y' (mapRenderIOState f s' s) 
            return $ map (\(a,(dcs, disc)) -> (a, (map (>>= (return . mapDrawcall f)) dcs, disc . f))) adcs

maybeFrame :: (s -> Maybe s') -> Frame os f s' () -> Frame os f s ()
maybeFrame f m = (guard' (isJust . f) >> mapFrame (fromJust . f) m) <|> return () 

guard' :: (s -> Bool) -> Frame os f s ()
guard' f = Frame $ FrameM $ tell (mempty, All . f) 

chooseFrame :: (s -> Either s' s'') -> Frame os f s' a -> Frame os f s'' a -> Frame os f s a
chooseFrame f a b = (guard' (isLeft . f) >> mapFrame (fromLeft . f) a) <|> mapFrame (fromRight . f) b 
    where fromLeft (Left x) = x
          fromRight (Right x) = x        

silenceFrame :: Frame os f' s a -> Frame os f s a
silenceFrame (Frame (FrameM m)) = Frame $ FrameM $   
    do s <- lift $ lift get
       let (adcs, s') = runState (runListT (runWriterT m)) s
       lift $ ListT $ do
        put s' 
        return $ map fst adcs

data CompiledFrame os f s = CompiledFrame (s -> IO ())


compileFrame :: (MonadIO m, MonadException m) => Frame os f x () -> ContextT os f m (CompiledFrame os f x)
compileFrame (Frame (FrameM m)) =
    let (adcs, FrameState _ _ s) = runState (runListT (runWriterT m)) newFrameState
    in do xs <- mapM (\(_,(dcs, disc)) -> do 
                                runF <- compile dcs s
                                return (disc, runF)) adcs
          let g ((disc, runF):ys) e = if getAll (disc e) then runF e else g ys e
              g  [] _               = return ()
          return $ CompiledFrame $ g xs    

newtype Render os f a = Render (IO a) deriving (Monad, Applicative, Functor)

render :: (MonadIO m, MonadException m) => Render os f () -> ContextT os f m ()
render (Render m) = liftContextIOAsync m

runFrame :: CompiledFrame os f x -> x -> Render os f ()
runFrame (CompiledFrame f) x = Render $ do
                                   putStrLn "-------------------------------------------------------------------------------------------"
                                   putStrLn "-------------------------------------------------------------------------------------------"
                                   putStrLn "Running frame"
                                   f x
                                   putStrLn "-------------------------------------------------------------------------------------------"
                                   putStrLn "-------------------------------------------------------------------------------------------"

     
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Main where

-- import           Game.Sequoia.Keyboard
import           Behavior
import           Client
import           Control.Monad.Trans.Writer (WriterT (..))
import           Control.Monad.Writer.Class (tell)
import qualified Data.DList as DL
import           Data.Ecstasy.Types (Ent (..))
import qualified Data.Map as M
import           GameData
import           Map
import           Overture hiding (init)
import           QuadTree.QuadTree (mkQuadTree)
import qualified QuadTree.QuadTree as QT


screenRect :: (V2, V2)
screenRect =
    ( V2 (-buffer)
         (-buffer)
    , V2 (gameWidth + buffer)
         (gameHeight + buffer)
    )
  where
    buffer = 64


separateTask :: Task ()
separateTask = do
  dyn0 <- lift $ gets _lsDynamic
  let zones = QT.zones dyn0
      howMany = 50 :: Int

  forever $ for_ (zip zones $ join $ repeat [0..howMany]) $ \(zone, i) -> do
    when (i == 0) $ void await
    ents <- lift $ getUnitsInZone zone
    let pairwise = do
          e1 <- ents
          e2 <- ents
          guard $ fst e1 < fst e2
          pure (e1, e2)
    for_ pairwise $ \((e1, p1), (e2, p2)) -> do
      zs <- lift . eover (someEnts [e1, e2]) $ do
        Unit <- query unitType
        -- TODO(sandy): constant for def size
        x <- queryDef 10 entSize
        pure (x, unchanged)
      when (length zs == 2) $ do
        let [s1, s2] = zs
            dir = normalize $ p1 - p2
            s   = s1 + s2
        lift . when (withinV2 p1 p2 s) $ do
          setEntity e1 unchanged
            { pos = Set $ p1 + dir ^* s1
            }
          setEntity e2 unchanged
            { pos = Set $ p2 - dir ^* s2
            }


initialize :: Game ()
initialize = do
  for_ [0 .. 10] $ \i -> do
    let mine = mod (round i) 2 == (0 :: Int)
    void $ createEntity newEntity
      { pos      = Just $ V2 (50 + i * 10 + bool 0 400 mine) (120 + i * 10)
      , attacks  = Just [gunAttackData]
      , entSize  = Just 7
      , acqRange = Just 125
      , speed    = Just 150
      , selected = bool Nothing (Just ()) mine
      , owner    = Just $ bool neutralPlayer mePlayer mine
      , unitType = Just Unit
      , hp       = Just $ Limit 100 100
      , moveType = Just GroundMovement
      }

  fromUnit @AttackCmd (Ent 0) (Ent 1) >>= resolveAttempt (Ent 0)
  fromUnit @AttackCmd (Ent 9) (Ent 10) >>= resolveAttempt (Ent 9)

  void $ createEntity newEntity
    { pos      = Just $ V2 700 300
    , attacks  = Just [gunAttackData]
    , entSize  = Just 10
    , speed    = Just 100
    , selected = Just ()
    , owner    = Just mePlayer
    , unitType = Just Unit
    , hp       = Just $ Limit 100 100
    , moveType = Just GroundMovement
    }

  void $ createEntity newEntity
    { pos      = Just $ V2 0 0
    , owner    = Just mePlayer
    , unitType = Just Building
    , hp       = Just $ Limit 100 100
    , gridSize = Just (2, 2)
    }

  start separateTask
  start acquireTask


acquireTask :: Task ()
acquireTask = forever $ do
  es <- lift . efor aliveEnts $ do
    with pos
    with attacks
    with acqRange
    without command
    queryEnt

  lift . for_ es $ \e ->
    fromInstant @AcquireCmd e >>= resolveAttempt e

  wait 0.5


update :: Time -> Game ()
update dt = do
  pumpTasks dt
  updateCommands dt


  -- death to infidels
  emap aliveEnts $ do
    Unit <- query unitType
    Limit health _ <- query hp

    pure $ if health <= 0
              then delEntity
              else unchanged


player :: Mouse -> Keyboard -> Game ()
player mouse kb = do
  playerNotWaiting mouse kb



playerNotWaiting :: Mouse -> Keyboard -> Game ()
playerNotWaiting mouse _kb = do
  when (mPress mouse buttonLeft) $ do
    modify $ lsSelBox ?~ mPos mouse

  when (mUnpress mouse buttonLeft) $ do
    -- TODO(sandy): finicky
    mp1 <- gets _lsSelBox
    for_ mp1 $ \p1 -> do
      lPlayer <- gets _lsPlayer

      modify $ lsSelBox .~ Nothing
      let p2 = mPos mouse
          (tl, br) = canonicalizeV2 p1 p2

      -- TODO(sandy): can we use "getUnitsInSquare" instead?
      emap aliveEnts $ do
        p    <- query pos
        o    <- query owner
        Unit <- query unitType

        guard $ not $ isEnemy lPlayer o

        pure unchanged
          { selected =
              case liftV2 (<=) tl p && liftV2 (<) p br of
                True  -> Set ()
                False -> Unset
          }

  when (mPress mouse buttonRight) $ do
    sel <- getSelectedEnts
    for_ sel $ \ent -> do
      amv <- fromLocation @MoveCmd ent
           $ mPos mouse
      resolveAttempt ent amv

  pure ()


cull :: [(V2, Form)] -> [Form]
cull = fmap (uncurry move)
     . filter (flip QT.pointInRect screenRect . fst)


draw :: Mouse -> Game [Form]
draw mouse = fmap (cull . DL.toList . fst)
           . surgery runWriterT
           $ do
  Map {..} <- gets _lsMap

  let emit a b = tell $ DL.singleton (a, b)
      screenCoords = do
        x <- [0..mapWidth]
        y <- [0..mapHeight]
        pure (x, y)

  for_ screenCoords $ \(x, y) ->
    for_ (mapGeometry x y) $ \f ->
      emit ((x + 1, y + 1) ^. centerTileScreen) f

  void . efor aliveEnts $ do
    p  <- query pos
    z  <- queryFlag selected
    o  <- queryDef neutralPlayer owner
    ut <- query unitType
    sz <- queryDef 10 entSize
    (gw, gh) <- queryDef (0, 0) gridSize

    let col = pColor o
    emit p $ group
      [ boolMonoid z $ traced' (rgb 0 1 0) $ circle $ sz + 5
      , case ut of
          Unit     -> filled col $ circle sz
          Missile  -> filled (rgb 0 0 0) $ circle 2
          Building -> filled (rgba 1 0 0 0.5)
                    $ polygon
                      [ (0,  0)  ^. centerTileScreen
                      , (gw, 0)  ^. centerTileScreen
                      , (gw, gh) ^. centerTileScreen
                      , (0,  gh) ^. centerTileScreen
                      ]
      ]

    -- debug draw
    void . optional $ do
      SomeCommand cmd <- query command
      Just (MoveCmd g@(_:_)) <- pure . listToMaybe $ cmd ^.. biplate
      Unit <- query unitType
      let ls = defaultLine { lineColor = rgba 0 1 0 0.5 }
      emit (V2 0 0) $ traced ls $ path $ p : g
      emit (last g) $ outlined ls $ circle 5

--     ( do
--       SomeCommand cmd <- query command
--       Just (AttackCmd att)  <- query attack
--       acq <- query acqRange

--       emit p $ traced' (rgba 0.7 0 0 0.3) $ circle $ _aRange att
--       emit p $ traced' (rgba 0.4 0.4 0.4 0.3) $ circle $ acq
--       ) <|> pure ()

  for_ screenCoords $ \(x, y) ->
    for_ (mapDoodads x y) $ \f ->
      emit ((x, y) ^. centerTileScreen) f

  void . efor aliveEnts $ do
    p <- query pos
    g <- query gfx
    emit p g

  box <- gets _lsSelBox
  for_ box $ \bpos -> do
    let (p1, p2) = canonicalizeV2 bpos $ mPos mouse
        size@(V2 w h) = p2 - p1
    emit (p1 + size ^* 0.5)
      . traced' (rgb 0 1 0)
      $ rect w h

  pure ()


main :: IO ()
main = play config (const $ run realState initialize player update draw) pure
  where
    config = EngineConfig (gameWidth, gameHeight) "Typecraft"
           $ rgb 0 0 0

    realState = LocalState
          { _lsSelBox     = Nothing
          , _lsPlayer     = mePlayer
          , _lsTasks      = []
          , _lsDynamic    = mkQuadTree (20, 20) (V2 800 600)
          , _lsMap        = maps M.! "rpg2k"
          }


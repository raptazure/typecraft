{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ViewPatterns      #-}

module Map where

import           Algorithm.JPS.Grid (Grid, newGrid)
import qualified Data.Map as M
import           Data.Tiled
import           Overture


tileWidth :: Num t => t
tileWidth = 64


tileHeight :: Num t => t
tileHeight = 32


getTileCrop :: Tileset -> Word32 -> Element
getTileCrop ts = \gid ->
  let g      = fromIntegral $ gid - tsInitialGid ts
      img    = head $ tsImages ts
      fs     = iSource img
      stride = iWidth img `div` tileWidth
      crop   = Crop (g `mod` stride * tileWidth)
                    (g `div` stride * tileHeight)
                    tileWidth
                    tileHeight
   in croppedImage crop $ "maps/" <> fs


drawSquare :: Layer -> [Tileset] -> Int -> Int -> Maybe Form
drawSquare (Layer {..}) ts = \x y ->
  M.lookup (x, y) layerData <&> \(tileGid -> gid) ->
    toForm $ getTileCrop (getTilesetForGid ts gid) gid
drawSquare _ _ = error "terrible layer choice"


getTilesetForGid :: [Tileset] -> Word32 -> Tileset
getTilesetForGid ts gid = head $ dropWhile ((> gid) . tsInitialGid) ts


orderTilesets :: [Tileset] -> [Tileset]
orderTilesets = sortBy . flip $ comparing tsInitialGid


parseMap :: TiledMap -> Map
parseMap TiledMap{..} =
    Map (drawSquare ground ts)
        (drawSquare doodads ts)
        (makeGrid mapWidth mapHeight collision)
        mapWidth
        mapHeight
  where
    getLayer name = maybe (error $ "no " <> name <> " layer") id
                  $ find ((== name) . layerName) mapLayers
    ground    = getLayer "ground"
    doodads   = getLayer "doodads"
    collision = getLayer "collision"
    ts = orderTilesets mapTilesets


makeGrid :: Int -> Int -> Layer -> Grid
makeGrid w h l = newGrid w h $ \x y -> 1
  -- maybe 1 (const 0) $  M.lookup (x, y) $ layerData l


maps :: M.Map String Map
maps = M.fromList $
  [ "hoth"
  ]
  <&> \i -> ( i
            , parseMap . unsafePerformIO
                       . loadMapFile
                       $ "maps/" <> i <> ".tmx"
            )
{-# NOINLINE maps #-}


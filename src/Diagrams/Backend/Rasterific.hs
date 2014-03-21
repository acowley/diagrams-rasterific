{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE TypeSynonymInstances      #-}
{-# LANGUAGE ViewPatterns              #-}

-------------------------------------------------------------------------------
-- |
-- Module      :  Diagrams.Backend.Rasterific
-- Copyright   :  (c) 2014 diagrams-rasterific team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  diagrams-discuss@googlegroups.com
--
-- A full-featured rendering backend for diagrams using Rasterific,
-- implemented natively in Haskell (making it easy to use on any
-- platform). Can create png, tif, bmp, jpg, and animated GIFs.
--
-- To invoke the Rasterific backend, you have three options.
--
-- * You can use the "Diagrams.Backend.Rasterific.CmdLine" module to create
--   standalone executables which output images when invoked.
--
-- * You can use the 'renderRasterific' function provided by this module,
--   which gives you more flexible programmatic control over when and
--   how images are output (making it easy to, for example, write a
--   single program that outputs multiple images, or one that outputs
--   images dynamically based on user input, and so on).
--
-- * For the most flexibility (/e.g./ if you want access to the
--   resulting Rasterific value directly in memory without writing it to
--   disk), you can manually invoke the 'renderDia' method from the
--   'Diagrams.Core.Types.Backend' instance for @Rasterific@.  In particular,
--   'Diagrams.Core.Types.renderDia' has the generic type
--
-- > renderDia :: b -> Options b v -> QDiagram b v m -> Result b v
--
-- (omitting a few type class constraints).  @b@ represents the
-- backend type, @v@ the vector space, and @m@ the type of monoidal
-- query annotations on the diagram.  'Options' and 'Result' are
-- associated data and type families, respectively, which yield the
-- type of option records and rendering results specific to any
-- particular backend.  For @b ~ Rasterific@ and @v ~ R2@, we have
--
-- > data Options Rasterific R2 = RasterificOptions
-- >          { _rasterificSizeSpec      :: SizeSpec2D -- ^ The requested size of the output
-- >          , _rasterificBypassAdjust  :: Bool       -- ^ Should the 'adjustDia' step be bypassed during rendering?
-- >          }
--
-- @
-- data family Render Rasterific R2 = 'R (RenderM ())'
-- @
--
-- @
-- type family Result Rasterific R2 = 'Image PixelRGBA8'
-- @
--
-- So the type of 'renderDia' resolves to
--
-- @
-- renderDia :: Rasterific -> Options Rasterific R2 -> QDiagram Rasterific R2 m -> 'Image PixelRGBA8'
-- @
--
-- which you could call like @renderDia Rasterific (RasterificOptions (Width 250))
-- myDiagram@.
--
-------------------------------------------------------------------------------
-- XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
--
-- To do:
--  Fix Opacity
--  Waiting for Rasterific:
--    Images
--    Text
--    Fill Rules
--    Dash offset
--
-- XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
-------------------------------------------------------------------------------
module Diagrams.Backend.Rasterific
  ( Rasterific(..)
  , B -- rendering token
  , Options(..)

  , renderRasterific
  , rasterificSizeSpec
  , rasterificBypassAdjust

  , writeJpeg

  ) where

import           Diagrams.Core.Compile       (RNode (..), RTree, toRTree)
import           Diagrams.Core.Transform
import           Diagrams.Prelude            hiding (Image, opacity, view)
import           Diagrams.TwoD.Adjust        (adjustDiaSize2D,
                                              setDefault2DAttributes)
import           Diagrams.TwoD.Path          (Clip (Clip))

import           Codec.Picture
import           Codec.Picture.Types         (dropTransparency, convertPixel)

import           GHC.Float                   (double2Float)
import qualified Graphics.Rasterific         as R
import           Graphics.Rasterific.Texture (uniformTexture)

import           Control.Lens                hiding (transform, ( # ))
import           Control.Monad               (when)
import           Control.Monad.StateStack
import           Control.Monad.Trans         (lift)

import qualified Data.ByteString.Lazy as L   (writeFile)
import           Data.Default.Class
import qualified Data.Foldable               as F
import           Data.Maybe                  (fromMaybe, isJust)
import           Data.Tree
import           Data.Typeable

import           System.FilePath             (takeExtension)

------- Debugging --------------------------------------------------------------
--import Debug.Trace

--traceShow' :: Show a => a -> a
--traceShow' x = traceShow x x
--------------------------------------------------------------------------------
-- | This data declaration is simply used as a token to distinguish
--   the Rasterific backend: (1) when calling functions where the type
--   inference engine would otherwise have no way to know which
--   backend you wanted to use, and (2) as an argument to the
--   'Backend' and 'Renderable' type classes.
data Rasterific = Rasterific
  deriving (Eq,Ord,Read,Show,Typeable)

type B = Rasterific

data RasterificState =
  RasterificState { _accumStyle :: Style R2
                    -- ^ The current accumulated style.
                  }

makeLenses ''RasterificState

instance Default RasterificState where
  def = RasterificState
        { _accumStyle       = mempty
        }

-- | The custom monad in which intermediate drawing options take
--   place; 'Graphics.Rasterific.Drawing' is Rasterific's own rendering
--   monad.
type RenderM a = StateStackT RasterificState RenderR a

type RenderR = R.Drawing PixelRGBA8

liftR :: RenderR a -> RenderM a
liftR = lift

runRenderM :: RenderM a -> RenderR a
runRenderM = flip evalStateStackT def

instance Backend Rasterific R2 where
  data Render  Rasterific R2 = R (RenderM ())
  type Result  Rasterific R2 = Image PixelRGBA8
  data Options Rasterific R2 = RasterificOptions
          { _rasterificSizeSpec      :: SizeSpec2D -- ^ The requested size of the output
          , _rasterificBypassAdjust  :: Bool       -- ^ Should the 'adjustDia' step be bypassed during rendering?
          }
    deriving (Show)

  doRender _ (RasterificOptions size _) (R r) =
    R.renderDrawing (round w) (round h) bgColor r'
    where
      r' = runRenderM r
      -- Everything except Dims is arbitrary. The backend
      -- should have first run 'adjustDia' to update the
      -- final size of the diagram with explicit dimensions,
      -- so normally we would only expect to get Dims anyway.
      (w,h) = case size of
                Width w'   -> (w',w')
                Height h'  -> (h',h')
                Dims w' h' -> (w',h')
                Absolute   -> (100,100)
      bgColor = PixelRGBA8 255 255 255 0

  renderData _ = renderRTree
               . Node (RStyle (mempty # recommendFillColor (transparent :: AlphaColour Double)))
               . (:[])
               . splitFills. toRTree

  adjustDia c opts d = if _rasterificBypassAdjust opts
                         then (opts, d # setDefault2DAttributes)
                         else adjustDia2D _rasterificSizeSpec
                                          setRasterificSizeSpec
                                          c opts (d # reflectY)
    where setRasterificSizeSpec sz o = o { _rasterificSizeSpec = sz }

-- XXX Don't do any freezing, will be removed after units branch is merged
adjustDia2D :: Monoid' m
            => (Options b R2 -> SizeSpec2D)
            -> (SizeSpec2D -> Options b R2 -> Options b R2)
            -> b -> Options b R2 -> QDiagram b R2 m
            -> (Options b R2, QDiagram b R2 m)
adjustDia2D getSize setSize b opts d
  = adjustDiaSize2D getSize setSize b opts (d # setDefault2DAttributes)

runR :: Render  Rasterific R2 -> RenderM ()
runR (R r) = r

instance Monoid (Render Rasterific R2) where
  mempty  = R $ return ()
  (R rd1) `mappend` (R rd2) = R (rd1 >> rd2)

renderRTree :: RTree Rasterific R2 a -> Render Rasterific R2
renderRTree (Node (RPrim accTr p) _) = render Rasterific (transform accTr p)
renderRTree (Node (RStyle sty) ts)   = R $ do
  save
  accumStyle %= (<> sty)
  runR $ F.foldMap renderRTree ts
  restore
-- XXX
-- Frozen nodes will be eliminated once units is merged so we don't
-- bother with them. Instead we temporarily use a custom adjustDia2D with
-- no freeze. This means that line widths will be wrong.
renderRTree (Node (RFrozenTr _) ts) = R $ do
  runR $ F.foldMap renderRTree ts
renderRTree (Node _ ts)              = F.foldMap renderRTree ts

rasterificSizeSpec :: Lens' (Options Rasterific R2) SizeSpec2D
rasterificSizeSpec = lens (\(RasterificOptions {_rasterificSizeSpec = s}) -> s)
                     (\o s -> o {_rasterificSizeSpec = s})

rasterificBypassAdjust :: Lens' (Options Rasterific R2) Bool
rasterificBypassAdjust = lens (\(RasterificOptions {_rasterificBypassAdjust = b}) -> b)
                     (\o b -> o {_rasterificBypassAdjust = b})

rasterificStrokeStyle :: Style v
                     -> (Float, R.Join, (R.Cap, R.Cap), Maybe R.DashPattern)
rasterificStrokeStyle s = (strokeWidth, strokeJoin, strokeCaps, dashPattern)
  where
    strokeWidth = double2Float $ fromMaybe 0.01 (getLineWidth <$> getAttr s)
    strokeJoin = fromMaybe (R.JoinMiter 0) (fromLineJoin . getLineJoin <$> getAttr s)
    strokeCaps = (strokeCap, strokeCap)
    strokeCap = fromMaybe (R.CapStraight 0) (fromLineCap . getLineCap <$> getAttr s)
    dashPattern = fromDashing . getDashing <$> getAttr s

fromLineCap :: LineCap -> R.Cap
fromLineCap LineCapButt   = R.CapStraight 0
fromLineCap LineCapRound  = R.CapRound
fromLineCap LineCapSquare = R.CapStraight 1

fromLineJoin :: LineJoin -> R.Join
fromLineJoin LineJoinMiter = R.JoinMiter 0
fromLineJoin LineJoinRound = R.JoinRound
fromLineJoin LineJoinBevel = R.JoinMiter 1

-- Rasterific does not currently support a dash offset.
fromDashing :: Dashing -> R.DashPattern
fromDashing (Dashing ds _) = map double2Float ds

-- | Get an accumulated style attribute from the render monad state.
getStyleAttrib :: AttributeClass a => (a -> b) -> RenderM (Maybe b)
getStyleAttrib f = (fmap f . getAttr) <$> use accumStyle

-- XXX Opacity does not seem to be working right. Colors are too translucent.
sourceColor :: Maybe (AlphaColour Double) -> Double -> PixelRGBA8
sourceColor Nothing  _ = PixelRGBA8 0 0 0 0
sourceColor (Just c) o = PixelRGBA8 r g b a
  where
    (r, g, b, a) = (int r', int g', int b', int (o * a'))
    (r',g',b', a') = colorToSRGBA c
    int x = round (255 * x)

v2 :: Double -> Double -> R.Point
v2 x y = R.V2 x' y'
  where
    (x', y') = (double2Float x, double2Float y)

p2v2 :: P2 -> R.Point
p2v2 p = uncurry v2 $ unp2 p

r2v2 :: R2 -> R.Point
r2v2 r = uncurry v2 $ unr2 r

renderSeg :: Located (Segment Closed R2) -> R.Primitive
renderSeg (viewLoc -> (p, (Linear (OffsetClosed v)))) =
  R.LinePrim $ R.Line p' (p' + r2v2 v)
  where
    p' = p2v2 p
renderSeg (viewLoc -> (p, (Cubic u1 u2 (OffsetClosed u3)))) =
  R.CubicBezierPrim $ R.CubicBezier q0 q1 q2 q3
  where
    (q0, q1, q2, q3) = (p2v2 p, q0 + r2v2 u1, q0 + r2v2 u2, q0 + r2v2 u3)
-- XXX dummy def to satisfy -Werror ?
renderSeg _ = R.LinePrim $ R.Line (R.V2 0 0) (R.V2 0 0)

renderPath :: Path R2 -> [[R.Primitive]]
renderPath p = (map . map) renderSeg (pathLocSegments p)

instance Renderable (Path R2) Rasterific where
  render _ p = R $ do
    f <- getStyleAttrib (toAlphaColour . getFillColor)
    s <- getStyleAttrib (toAlphaColour . getLineColor)
    o <- fromMaybe 1 <$> getStyleAttrib getOpacity
    sty <- use accumStyle

    let fColor = uniformTexture $ sourceColor f o
        sColor = uniformTexture $ sourceColor s o
        (l, j, c, d) = rasterificStrokeStyle sty

        -- For stroking we need to keep all of the contours separate.
        primList = renderPath p

        -- For filling we need to put them togehter.
        prms = concat primList

    -- If a dashing pattern is provided, use @dashedStroke@ otherwise @stroke@.
    maybe (liftR (R.withTexture sColor $ mapM_ (R.stroke l j c) primList))
          (\dsh -> liftR (R.withTexture sColor $ mapM_ (R.dashedStroke dsh l j c) primList))
          d
    -- If there is a clipping path we must use @withClipping@.
    maybe (when (isJust f) $ liftR (R.withTexture fColor $ R.fill prms))
          (\paths -> when (isJust f) $ liftR (R.withClipping
                          (R.fill (concat . concat $ (map renderPath paths)))
                          (R.withTexture fColor $ R.fill prms)))
          (op Clip <$> getAttr sty)

instance Renderable (Segment Closed R2) Rasterific where
  render b = render b . (fromSegments :: [Segment Closed R2] -> Path R2) . (:[])

instance Renderable (Trail R2) Rasterific where
  render b = render b . pathFromTrail

writeJpeg :: FilePath -> Result Rasterific R2 -> IO ()
writeJpeg outFile img = L.writeFile outFile bs
  where
    bs = encodeJpegAtQuality 100 (pixelMap (convertPixel . dropTransparency) img)

renderRasterific :: FilePath -> SizeSpec2D -> Diagram Rasterific R2 -> IO ()
renderRasterific outFile sizeSpec d = writer outFile img
  where
    writer = case takeExtension outFile of
              ".png" -> writePng
              ".tif" -> writeTiff
              ".bmp" -> writeBitmap
              ".jpg" -> writeJpeg
              _      -> writePng
    img = renderDia Rasterific (RasterificOptions sizeSpec False) d

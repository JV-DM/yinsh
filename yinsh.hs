module Main where

import Haste
import Haste.Graphics.Canvas
import Data.List (minimumBy)
import Data.Ord (comparing)
import Data.IORef
import Control.Monad (when)

-- $setup
-- >>> import Data.List (sort, nub)
-- >>> import Test.QuickCheck
-- >>> let boardCoords = elements coords
-- >>> instance Arbitrary Direction where arbitrary = elements directions

-- Color theme
-- http://www.colourlovers.com/palette/15/tech_light
green  = RGB  209 231  81
blue   = RGB   38 173 228
white  = RGB  255 255 255

-- Dimensions
spacing         = 60 :: Double
markerWidth     = 20 :: Double
ringInnerRadius = 22 :: Double
ringWidth       = 6 :: Double
originX         = -15 :: Double
originY         = 495 :: Double

-- | Yinsh hex coordinates
type YCoord = (Int, Int)

data Direction = N | NE | SE | S | SW | NW
                 deriving (Eq, Enum, Bounded, Show)

-- | All directions
directions :: [Direction]
directions = [minBound .. maxBound]

-- | Rotate direction by 60° (positive, ccw)
rotate60 :: Direction -> Direction
rotate60 NW = N
rotate60 d  = succ d

-- | Opposite direction
--
-- prop> (opposite . opposite) d == d
opposite :: Direction -> Direction
opposite = rotate60 . rotate60 . rotate60

-- | Vector to the next point on the board in a given direction
vector :: Direction -> YCoord
vector N  = ( 0,  1)
vector NE = ( 1,  1)
vector SE = ( 1,  0)
vector S  = ( 0, -1)
vector SW = (-1, -1)
vector NW = (-1,  0)

-- | Player types: black & white or blue & green
data Player = B | W
              deriving Eq

-- | Next player
switch :: Player -> Player
switch B = W
switch W = B

-- | Translate hex coordinates to screen coordinates
screenPoint :: YCoord -> Point
screenPoint (ya, yb) = (0.5 * sqrt 3 * x' + originX, - y' + 0.5 * x' + originY)
    where x' = spacing * fromIntegral ya
          y' = spacing * fromIntegral yb

-- could be generated by generating all triangular lattice points smaller
-- than a certain cutoff (~ 5)
numPoints :: [[Int]]
numPoints = [[2..5], [1..7], [1..8], [1..9],
             [1..10], [2..10], [2..11], [3..11],
             [4..11], [5..11], [7..10]]

-- | All points on the board
--
-- >>> length coords
-- 85
--
coords :: [YCoord]
coords = concat $ zipWith (\list ya -> map (\x -> (ya, x)) list) numPoints [1..]

-- | Check if two points are connected by a line
--
-- >>> connected (3, 4) (8, 4)
-- True
--
-- prop> connected c1 c2 == connected c2 c1
--
connected :: YCoord -> YCoord -> Bool
connected (x, y) (a, b) =        x == a
                          ||     y == b
                          || x - y == a - b

-- | List of points reachable from a certain point
--
-- Every point should be reachable within two moves
-- prop> forAll boardCoords (\c -> sort coords == sort (nub (reachable c >>= reachable)))
--
reachable :: YCoord -> [YCoord]
reachable c = filter (connected c) coords

validRingMoves :: Board -> YCoord -> [YCoord]
validRingMoves b start = filter (freeCoord b) $ concatMap (validInDir False start) directions
    where markerPos = [ c | Marker _ c <- b ]
          ringPos   = [ c | Ring _ c <- b ]
          validInDir :: Bool -> YCoord -> Direction -> [YCoord]
          validInDir jumped c d = c : rest
              where nextPoint = c `addC` vector d
                    rest = if nextPoint `elem` coords && nextPoint `notElem` ringPos
                           then if nextPoint `elem` markerPos
                                then validInDir True nextPoint d
                                else if jumped
                                     then [nextPoint]
                                     else validInDir False nextPoint d
                           else []
                    hasJumped = hasJumped || c `elem` markerPos

-- | Vectorially add two coords
addC :: YCoord -> YCoord -> YCoord
addC (x1, y1) (x2, y2) = (x1 + x2, y1 + y2)

-- | Get all nearest neighbors
--
-- Every point has neighbors
--
-- >>> sort coords == sort (nub (coords >>= neighbors))
-- True
--
-- Every point is a neighbor of its neighbor
-- prop> forAll boardCoords (\c -> c `elem` (neighbors c >>= neighbors))
--
neighbors :: YCoord -> [YCoord]
neighbors c = filter (`elem` coords) adjacent
    where adjacent = mapM (addC . vector) directions c

-- | Get the coordinates of a players markers
markerCoords :: Board -> Player -> [YCoord]
markerCoords b p = [ c | Marker p' c <- b, p == p' ]

-- | Get the coordinates of a players rings
ringCoords :: Board -> Player -> [YCoord]
ringCoords b p = [ c | Ring p' c <- b, p == p' ]

-- | Check if a certain point on the board is free
freeCoord :: Board -> YCoord -> Bool
freeCoord b c = c `notElem` occupied
    where occupied = [ c | Ring _ c <- b ] ++ [ c | Marker _ c <- b ]

-- | Check if a coordinate is part of a combination of five in a row
--
-- prop> partOfCombination (fiveAdjacent c d) c == True
partOfCombination :: [YCoord] -> YCoord -> Bool
partOfCombination markers start = any (partOfCombinationD markers start) [NW, N, NE]

partOfCombinationD :: [YCoord] -> YCoord -> Direction -> Bool
partOfCombinationD markers start dir = length right + length left >= 2 + 4  -- the start point is counted twice
    where right = takeAvailable dir
          left  = takeAvailable (opposite dir)
          takeAvailable d = takeWhile (`elem` markers) $ iterate (`addC` vector d) start

-- | Get the five adjacent (including start) coordinates in a given direction
fiveAdjacent :: YCoord -> Direction -> [YCoord]
fiveAdjacent start dir = take 5 $ iterate (`addC` vector dir) start

-- -- | Test if A is subset of B
-- --
-- -- prop> x `subset` x     == True
-- -- prop> x `subset` (y:x) == True
-- subset :: Eq a => [a] -> [a] -> Bool
-- subset a b = all (`elem` b) a

-- -- | Get five adjacent marker coordinates, if the markers are on the board
-- maybeFiveAdjacent :: [YCoord] -> YCoord -> Direction -> Maybe [YCoord]
-- maybeFiveAdjacent list start dir = Just []

data DisplayState = BoardOnly GameState
                  | WaitTurn GameState

data Element = Ring Player YCoord
             | Marker Player YCoord
             deriving Eq

data TurnMode = AddRing
              | AddMarker
              | MoveRing YCoord
              | RemoveRing

type Board = [Element]

data GameState = GameState
    { activePlayer :: Player
    , turnMode :: TurnMode
    , board :: Board
    }

-- | All grid points as screen coordinates
points :: [Point]
points = map screenPoint coords

-- | Translate by hex coordinate
translateC :: YCoord -> Picture () -> Picture ()
translateC = translate . screenPoint

playerColor :: Player -> Color
playerColor B = blue
playerColor W = green

setPlayerColor :: Player -> Picture ()
setPlayerColor = setFillColor . playerColor

pRing :: Player -> Picture ()
pRing p = do
    setPlayerColor p
    fill circL
    stroke circL
    setFillColor white
    fill circS
    stroke circS
    pCross ringInnerRadius
        where circL = circle (0, 0) (ringInnerRadius + ringWidth)
              circS = circle (0, 0) ringInnerRadius

pMarker :: Player -> Picture ()
pMarker p = do
    setPlayerColor p
    fill circ
    stroke circ
        where circ = circle (0, 0) markerWidth

pElement :: Element -> Picture ()
pElement (Ring p c)   = translateC c $ pRing p
pElement (Marker p c) = translateC c $ pMarker p

pCross :: Double -> Picture ()
pCross len = do
    l
    rotate (2 * pi / 3) l
    rotate (4 * pi / 3) l
        where l = stroke $ line (0, -len) (0, len)

pHighlightRing :: Picture ()
pHighlightRing = fill $ circle (0, 0) (markerWidth + 4)

pHighlight :: Board -> Player -> Picture ()
pHighlight b p = do
    let mc  = markerCoords b p
    let mcH = filter (partOfCombination mc) mc
    mapM_ (`translateC` pHighlightRing) mcH

pDot :: Picture ()
pDot = do
    setFillColor $ RGB 0 0 0
    fill $ circle (0, 0) 5

pBoard :: Board -> Picture ()
pBoard b = do
    -- Draw grid
    sequence_ $ mapM translate points (pCross (0.5 * spacing))

    -- Draw thick borders for markers which are part of five in a row
    mapM_ (pHighlight b) [B, W]

    -- Draw markers
    mapM_ pElement b

    -- sequence_ $ mapM (translate . screenPoint) (reachable (3, 6)) pDot
    -- Testing
    -- mapM_ (`translateC` pDot) $ fiveAdjacent (6, 6) NW

pAction :: Board -> TurnMode -> YCoord -> Player -> Picture ()
pAction b AddMarker mc p        = when (mc `elem` ringCoords b p) $ pElement (Marker p mc)
pAction b AddRing mc p          = when (freeCoord b mc) $ pElement (Ring p mc)
pAction b (MoveRing start) mc p = do
    let allowed = validRingMoves b start
    mapM_ (`translateC` pDot) allowed
    when (mc `elem` allowed) $ pElement (Ring p mc)
pAction b RemoveRing mc p       = return ()

-- | Render everything that is seen on the screen
pDisplay :: DisplayState
         -> YCoord         -- ^ Coordinate close to mouse cursor
         -> Picture ()
pDisplay (BoardOnly gs) _ = pBoard (board gs)
pDisplay (WaitTurn gs) mc = do
    pBoard (board gs)
    pAction (board gs) (turnMode gs) mc (activePlayer gs)

-- pDisplay ConnectedPoints c = do
--     pBoard
--     sequence_ $ mapM (translate . screenPoint) (reachable c) pDot

-- | Get the board coordinate which is closest to the given screen
-- coordinate point
--
-- prop> closestCoord p == (closestCoord . screenPoint . closestCoord) p
closestCoord :: Point -> YCoord
closestCoord (x, y) = coords !! snd lsort
    where lind = zipWith (\p i -> (dist p, i)) points [0..]
          lsort = minimumBy (comparing fst) lind
          dist (x', y') = (x - x')^2 + (y - y')^2

testBoard :: Board
testBoard = [ Ring B (3, 4)
            , Ring B (4, 9)
            , Ring B (7, 9)
            , Ring W (8, 7)
            , Ring W (6, 3)
            , Ring W (4, 8)
            , Marker W (6, 4)
            , Marker W (6, 5)
            , Marker W (6, 7)
            , Marker W (5, 5)
            , Marker W (4, 5)
            , Marker W (3, 5)
            , Marker B (6, 6)]

testGameState = GameState {
    activePlayer = B,
    turnMode = AddRing,
    board = testBoard
}

testDisplayState = WaitTurn testGameState

showMoves :: Canvas -> DisplayState -> (Int, Int) -> IO ()
showMoves can ds point = render can $ pDisplay ds (coordFromXY point)

coordFromXY :: (Int, Int) -> YCoord
coordFromXY (x, y) = closestCoord (fromIntegral x, fromIntegral y)

newDisplayState :: DisplayState  -- ^ old state
                -> YCoord        -- ^ clicked coordinate
                -> DisplayState  -- ^ new state
newDisplayState (WaitTurn gs) cc =
    case turnMode gs of
        AddRing -> WaitTurn (
                       gs { activePlayer = nextPlayer
                          , turnMode = if numRings < 9 then AddRing else AddMarker
                          , board = Ring (activePlayer gs) cc : board gs
                       })
            where numRings = length [ 0 | Ring _ _ <- board gs ]
        AddMarker -> WaitTurn (
                       gs { turnMode = MoveRing cc
                          , board = Marker (activePlayer gs) cc : removeRing (board gs)
                       })
            where removeRing = filter ((/=) $ Ring (activePlayer gs) cc)
        (MoveRing _) -> WaitTurn (
                       gs { activePlayer = nextPlayer
                          , turnMode = AddMarker
                          , board = Ring (activePlayer gs) cc : board gs
                       })
    where nextPlayer = switch (activePlayer gs)

main :: IO ()
main = do
    Just can <- getCanvasById "canvas"
    Just ce  <- elemById "canvas"

    ioDS <- newIORef testDisplayState

    -- draw initial board
    render can (pBoard testBoard)

    ce `onEvent` OnMouseMove $ \point -> do
        ds <- readIORef ioDS
        showMoves can ds point

    ce `onEvent` OnClick $ \_ point ->
        modifyIORef' ioDS $ \old -> newDisplayState old (coordFromXY point)

    return ()

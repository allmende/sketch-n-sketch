-- LangHtml.elm

module LangHtml where
-- module LangSvg (valToHtml, valToIndexedTree, printIndexedTree) where

import Html
import Html.Attributes as HA
import Svg
import Svg.Attributes as A
import VirtualDom

-- in Svg.elm:
--   type alias Svg = VirtualDom.Node
--   type alias Attribute = VirtualDom.Property

-- in Html.elm:
--   type alias Html = VirtualDom.Node

import Debug
import Set
import String
import Char
import Dict exposing (Dict)
import ColorNum

import Lang exposing (..)
import Utils

------------------------------------------------------------------------------

attr = VirtualDom.attribute
html  = Html.node

-- TODO probably want to factor HTML attributes and SVG attributes into
-- records rather than lists of lists of ...

valToHtml : Int -> Int -> Val -> Html.Html
valToHtml w h (VList [VBase (String "html"), VList vs1, VList vs2]) =
  let wh = [numAttrToVal "width" w, numAttrToVal "height" h] in
  let v' = VList [VBase (String "html"), VList (wh ++ vs1), VList vs2] in
  compileValToNode v'
    -- NOTE: not checking if width/height already in vs1

compileValToNode : Val -> VirtualDom.Node
compileValToNode v = case v of
  VList [VBase (String "TEXT"), VBase (String s)] -> VirtualDom.text s
  VList [VBase (String f), VList vs1, VList vs2] ->
    (html f) (compileAttrVals vs1) (compileNodeVals vs2)

compileNodeVals = List.map compileValToNode
compileAttrVals = List.map (uncurry compileAttr << valToAttr)
compileAttrs    = List.map (uncurry compileAttr)
compileAttr k v = (attr k) (strAVal v)

numAttrToVal a i =
  VList [VBase (String a), VConst (toFloat i, dummyTrace)]

type AVal
  = ANum NumTr
  | AString String
  | APoints (List Point)
  | ARgba Rgba
  | AColorNum NumTr -- Utils.numToColor [0,500)

maxColorNum   = 500
clampColorNum = Utils.clamp 0 (maxColorNum - 1)

type alias Point = (NumTr, NumTr)
type alias Rgba  = (NumTr, NumTr, NumTr, NumTr)

-- toNum    (ANum (i,_)) = i
-- toNumTr  (ANum (i,t)) = (i,t)

-- temporary way to ignore numbers specified as strings (also see Sync)

toNum a = case a of
  ANum (n,_) -> n
  AString s  -> case String.toFloat s of
                  Ok n -> n

toNumTr a = case a of
  ANum (n,t) -> (n,t)
  AColorNum (n,t) -> (n,t)
  AString s  -> case String.toFloat s of
                  Ok n -> (n, dummyTrace)

--TODO: Add additional HTML attrs
valToAttr (VList [VBase (String k), v]) =
  case Debug.log "(k,v)" (k, v) of
    ("fill", VList vs)    -> (k, ARgba <| valToRgba vs) --Double check this, might be 'color'
    ("fill", VConst it)   -> (k, AColorNum it)
    (_, VConst it)        -> (k, ANum it)
    (_, VBase (String s)) -> (k, AString s)

valToRgba [VConst r, VConst g, VConst b, VConst a] = (r,g,b,a)
rgbaToVal (r,g,b,a) = [VConst r, VConst g, VConst b, VConst a]

strRgba (r_,g_,b_,a_) =
  strRgba_ (List.map fst [r_,g_,b_,a_])

strRgba_ rgba =
  "rgba" ++ Utils.parens (Utils.commas (List.map toString rgba))

strAVal a = case a of
  AString s -> s
  ANum it   -> toString (fst it)
  ARgba tup -> strRgba tup
  AColorNum n ->
    -- slight optimization:
    strRgba_ (ColorNum.convert (fst n))
    -- let (r,g,b) = Utils.numToColor maxColorNum (fst n) in
    -- strRgba_ [r,g,b,1]

valOfAVal a = case a of
  AString s -> VBase (String s)
  ANum it   -> VConst it
  ARgba tup -> VList (rgbaToVal tup)
  AColorNum nt -> VConst nt

valOfAttr (k,a) = VList [VBase (String k), valOfAVal a]

------------------------------------------------------------------------------

type alias NodeKind = String
type alias NodeId = Int
type alias IndexedTree = Dict NodeId IndexedTreeNode
type alias Attr = (String, AVal)
type IndexedTreeNode
  = TextNode String
  | HtmlNode NodeKind (List Attr) (List NodeId)
type alias RootedIndexedTree = (NodeId, IndexedTree)

children n = case n of {TextNode _ -> []; HtmlNode _ _ l -> l}

emptyTree : RootedIndexedTree
emptyTree = valToIndexedTree <| VList [VBase (String "html"), VList [], VList []]

valToIndexedTree : Val -> RootedIndexedTree
valToIndexedTree v =
  let (nextId,tree) = valToIndexedTree_ v (1, Dict.empty) in
  let rootId = nextId - 1 in
  (rootId, tree)

valToIndexedTree_ v (nextId, d) = case v of

  VList [VBase (String "TEXT"), VBase (String s)] ->
    (1 + nextId, Dict.insert nextId (TextNode s) d)

  VList [VBase (String kind), VList vs1, VList vs2] ->
    let processChild vi (a_nextId, a_graph , a_children) =
      let (a_nextId',a_graph') = valToIndexedTree_ vi (a_nextId, a_graph) in
      let a_children'          = (a_nextId' - 1) :: a_children in
      (a_nextId', a_graph', a_children') in
    let (nextId',d',children) = List.foldl processChild (nextId,d,[]) vs2 in
    let node = HtmlNode kind (List.map valToAttr vs1) (List.reverse children) in
    (1 + nextId', Dict.insert nextId' node d')

  _ -> Debug.crash ("LangHtml.valToIndexTree_: " ++ strVal v)

printIndexedTree : Val -> String
printIndexedTree = valToIndexedTree >> snd >> strEdges

strEdges : IndexedTree -> String
strEdges =
     Dict.toList
  >> List.map (\(i,n) ->
       let l = List.map toString (children n) in
       toString i ++ " " ++ Utils.braces (Utils.spaces l))
  >> Utils.lines


------------------------------------------------------------------------------
-- Printing to SVG format

printHtml : RootedIndexedTree -> String
printHtml (rootId, tree) = printNode 0 tree rootId

printNode k slate i =
  case Utils.justGet i slate of
    TextNode s -> s
    HtmlNode kind l1 [] ->
      Utils.delimit "<" ">" (kind ++ printAttrs l1) ++
      Utils.delimit "</" ">" kind
    HtmlNode kind l1 l2 ->
      Utils.delimit "<" ">" (kind ++ printAttrs l1) ++ "\n" ++
      printNodes (k+1) slate l2 ++ "\n" ++
      tab k ++ Utils.delimit "</" ">" kind

printNodes k slate =
  Utils.lines << List.map ((++) (tab k) << printNode k slate)

printAttrs l = case l of
  [] -> ""
  _  -> " " ++ Utils.spaces (List.map printAttr l)

printAttr (k,v) =
  k ++ "=" ++ Utils.delimit "'" "'" (strAVal v)

--TODO : may need to fiddle with attrs when outputting html

------------------------------------------------------------------------------
-- Zones

--TODO: rework zones according to makeZones in a restructured InterfaceView2

--type alias Zone = String

---- NOTE: would like to use only the following definition, but datatypes
---- aren't comparable... so using Strings for storing in dictionaries, but
---- using the following for pattern-matching purposes

--type RealZone = Z String | ZPoint Int | ZEdge Int

addi s i = s ++ toString i

--realZoneOf s =
--  Maybe.withDefault (Z s) (toZPoint s `Utils.plusMaybe` toZEdge s)

--toZPoint s =
--  Utils.mapMaybe
--    (ZPoint << Utils.fromOk_ << String.toInt)
--    (Utils.munchString "Point" s)

--toZEdge s =
--  Utils.mapMaybe
--    (ZEdge << Utils.fromOk_ << String.toInt)
--    (Utils.munchString "Edge" s)

-- TODO perhaps define Interface callbacks here

--zones = [
--    ("html", [])
--  , ("circle",
--      [ ("Interior", ["cx", "cy"])
--      , ("Edge", ["r"])
--      ])
--  , ("ellipse",
--      [ ("Interior", ["cx", "cy"])
--      , ("Edge", ["rx", "ry"])
--      ])
--  , ("rect",
--      [ ("Interior", ["x", "y"])
--      , ("TopLeftCorner", ["x", "y", "width", "height"])
--      , ("TopRightCorner", ["y", "width", "height"])
--      , ("BotRightCorner", ["width", "height"])
--      , ("BotLeftCorner", ["x", "width", "height"])
--      , ("LeftEdge", ["x", "width"])
--      , ("TopEdge", ["y", "height"])
--      , ("RightEdge", ["width"])
--      , ("BotEdge", ["height"])
--      ])
--  , ("line",
--      [ ("Point1", ["x1", "y1"])
--      , ("Point2", ["x2", "y2"])
--      , ("Edge", ["x1", "y1", "x2", "y2"])
--      ])
--  -- TODO
--  , ("g", [])
--  , ("text", [])
--  , ("tspan", [])

--  -- symptom of the Sync.Dict0 type. see Sync.nodeToAttrLocs_.
--  , ("DUMMYTEXT", [])

  -- NOTE: these are computed in Sync.getZones
  -- , ("polygon", [])
  -- , ("polyline", [])
  -- , ("path", [])

-- Noodling about what it would take to replace LangSvg with this, and have the
-- output be retargeted to elm-html instead of elm-svg.
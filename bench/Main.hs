{-# LANGUAGE PackageImports #-}
module Main (main) where

import Control.DeepSeq
import Data.Maybe
import Data.Attoparsec.ByteString as Atto
import Data.ByteString as B
import Data.ByteString.Lazy as BL
import Data.List as L
import Criterion.Main
import System.Environment

import "bencode"   Data.BEncode     as A
import             Data.AttoBencode as B
import             Data.AttoBencode.Parser as B
import "bencoding" Data.BEncode     as C

instance NFData A.BEncode where
    rnf (A.BInt    i) = rnf i
    rnf (A.BString s) = rnf s
    rnf (A.BList   l) = rnf l
    rnf (A.BDict   m) = rnf m

instance NFData B.BValue where
    rnf (B.BInt    i) = rnf i
    rnf (B.BString s) = rnf s
    rnf (B.BList   l) = rnf l
    rnf (B.BDict   d) = rnf d

instance NFData C.BEncode where
    rnf (C.BInteger i) = rnf i
    rnf (C.BString  s) = rnf s
    rnf (C.BList    l) = rnf l
    rnf (C.BDict    d) = rnf d

getRight :: Either String a -> a
getRight (Left e) = error e
getRight (Right x) = x

main :: IO ()
main = do
  (path : args) <- getArgs
  torrentFile   <- B.readFile path
  let lazyTorrentFile = fromChunks [torrentFile]

  case rnf (torrentFile, lazyTorrentFile) of
    () -> return ()

  withArgs args $
       defaultMain
       [ bench "decode/bencode"     $ nf A.bRead                            lazyTorrentFile
       , bench "decode/AttoBencode" $ nf (getRight . Atto.parseOnly bValue) torrentFile
       , bench "decode/bencoding"   $ nf (getRight . C.decode)              torrentFile

       , let Just v = A.bRead lazyTorrentFile in
         bench "encode/bencode"     $ nf A.bPack v
       , let Right v = Atto.parseOnly bValue torrentFile in
         bench "encode/AttoBencode" $ nf B.encode v
       , let Right v = C.decode torrentFile in
         bench "encode/bencoding"   $ nf C.encode v

       , bench "decode+encode/bencode"     $ nf (A.bPack  . fromJust . A.bRead)
               lazyTorrentFile
       , bench "decode+encode/AttoBencode" $ nf (B.encode . getRight . Atto.parseOnly bValue)
               torrentFile
       , bench "decode+encode/bencoding"   $ nf (C.encode . getRight . C.decode)
               torrentFile

       , bench "list10000int/bencode/encode" $ nf
           (A.bPack . A.BList . L.map (A.BInt . fromIntegral))
             [0..10000 :: Int]

       , bench "list10000int/attobencode/encode" $ nf B.encode [1..20000 :: Int]
       , bench "list10000int/bencoding/encode" $ nf C.encoded [1..20000 :: Int]


       , let d = A.bPack $ A.BList $
                 L.map A.BInt (L.replicate 1000 (0 :: Integer))
         in d `seq` (bench "list10000int/bencode/decode" $ nf
            (fromJust . A.bRead :: BL.ByteString -> A.BEncode) d)

       , let d = BL.toStrict (C.encoded (L.replicate 10000 ()))
         in d `seq` (bench "list10000unit/bencoding/decode" $ nf
            (C.decoded :: B.ByteString -> Either String [()]) d)

       , let d = BL.toStrict (C.encoded (L.replicate 10000 (0 :: Int)))
         in d `seq` (bench "list10000int/bencoding/decode" $ nf
            (C.decoded :: B.ByteString -> Either String [Int]) d)

       ]

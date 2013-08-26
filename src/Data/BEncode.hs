-- TODO: make int's instances platform independent so we can make
-- library portable.

-- |
--   Copyright   :  (c) Sam T. 2013
--   License     :  MIT
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  stable
--   Portability :  non-portable
--
--   This module provides convinient and fast way to serialize,
--   deserealize and construct/destructure Bencoded values with
--   optional fields.
--
--   It supports four different types of values:
--
--     * byte strings — represented as 'ByteString';
--
--     * integers     — represented as 'Integer';
--
--     * lists        - represented as ordinary lists;
--
--     * dictionaries — represented as 'Map';
--
--    To serialize any other types we need to make conversion.  To
--    make conversion more convenient there is type class for it:
--    'BEncodable'. Any textual strings are considered as UTF8 encoded
--    'Text'.
--
--    The complete Augmented BNF syntax for bencoding format is:
--
--
--    > <BE>    ::= <DICT> | <LIST> | <INT> | <STR>
--    >
--    > <DICT>  ::= "d" 1 * (<STR> <BE>) "e"
--    > <LIST>  ::= "l" 1 * <BE>         "e"
--    > <INT>   ::= "i"     <SNUM>       "e"
--    > <STR>   ::= <NUM> ":" n * <CHAR>; where n equals the <NUM>
--    >
--    > <SNUM>  ::= "-" <NUM> / <NUM>
--    > <NUM>   ::= 1 * <DIGIT>
--    > <CHAR>  ::= %
--    > <DIGIT> ::= "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"
--
--
--    This module is considered to be imported qualified.
--
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE Trustworthy       #-}
{-# LANGUAGE CPP               #-}

#if __GLASGOW_HASKELL__ >= 702
{-# LANGUAGE TypeOperators          #-}
{-# LANGUAGE DefaultSignatures      #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE ScopedTypeVariables    #-}
#endif

module Data.BEncode
       ( -- * Datatype
         BEncode(..)
       , Dict

         -- * Construction && Destructuring
       , BEncodable (..)
       , dictAssoc
       , Result

         -- ** Dictionaries
         -- *** Building
       , (-->)
       , (-->?)
       , fromAssocs
       , fromAscAssocs

         -- *** Extraction
       , reqKey
       , optKey
       , (>--)
       , (>--?)

         -- * Serialization
       , encode
       , decode
       , encoded
       , decoded

         -- * Predicates
       , isInteger
       , isString
       , isList
       , isDict

         -- * Extra
       , builder
       , parser
       , decodingError
       , printPretty
       ) where


import Control.Applicative
import Control.Monad
import Data.Int
import Data.Maybe         (mapMaybe)
import Data.Monoid        -- (mempty, (<>))
import Data.Foldable      (foldMap)
import Data.Traversable   (traverse)
import Data.Word          (Word8, Word16, Word32, Word64, Word)
import           Data.Map (Map)
import qualified Data.Map as M
import           Data.Set (Set)
import qualified Data.Set as S
import           Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as P
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString.Lazy.Builder as B
import qualified Data.ByteString.Lazy.Builder.ASCII as ASCII
import           Data.ByteString.Internal as B (c2w, w2c)
import           Data.Text (Text)
import qualified Data.Text.Encoding as T
import           Data.Version
import           Text.PrettyPrint hiding ((<>))
import qualified Text.ParserCombinators.ReadP as ReadP

#if __GLASGOW_HASKELL__ >= 702
import GHC.Generics
#endif

type Dict = Map ByteString BEncode

-- | 'BEncode' is straightforward ADT for b-encoded values. Please
-- note that since dictionaries are sorted, in most cases we can
-- compare BEncoded values without serialization and vice versa.
-- Lists is not required to be sorted through.  Also note that
-- 'BEncode' have JSON-like instance for 'Pretty'.
--
data BEncode = BInteger {-# UNPACK #-} !Int64
             | BString  !ByteString
             | BList    [BEncode]
             | BDict    Dict
               deriving (Show, Read, Eq, Ord)

type Result = Either String

class BEncodable a where
  toBEncode   :: a -> BEncode

#if __GLASGOW_HASKELL__ >= 702
  default toBEncode
    :: Generic a
    => GBEncodable (Rep a) BEncode
    => a -> BEncode

  toBEncode = gto . from
#endif

  fromBEncode :: BEncode -> Result a

#if __GLASGOW_HASKELL__ >= 702
  default fromBEncode
    :: Generic a
    => GBEncodable (Rep a) BEncode
    => BEncode -> Result a

  fromBEncode x = to <$> gfrom x
#endif

decodingError :: String -> Result a
decodingError s = Left ("fromBEncode: unable to decode " ++ s)
{-# INLINE decodingError #-}

{--------------------------------------------------------------------
  Generics
--------------------------------------------------------------------}

{- NOTE: SELECTORS FOLDING/UNFOLDING
Both List and Map are monoids:

* if fields are named, we fold record to the map;
* otherwise we collect fields using list;

and then unify them using BDict and BList constrs.
-}

#if __GLASGOW_HASKELL__ >= 702

class GBEncodable f e where
  gto   :: f a -> e
  gfrom :: e -> Result (f a)

instance BEncodable f
      => GBEncodable (K1 R f) BEncode where
  {-# INLINE gto #-}
  gto = toBEncode . unK1

  {-# INLINE gfrom #-}
  gfrom x = K1 <$> fromBEncode x

instance (Eq e, Monoid e)
      => GBEncodable U1 e where
  {-# INLINE gto #-}
  gto U1 = mempty

  {-# INLINE gfrom #-}
  gfrom x
    | x == mempty = pure U1
    |   otherwise = decodingError "U1"

instance (GBEncodable a [BEncode], GBEncodable b [BEncode])
      => GBEncodable (a :*: b) [BEncode] where
  {-# INLINE gto #-}
  gto (a :*: b) = gto a ++ gto b

  {-# INLINE gfrom #-}
  gfrom (x : xs) = (:*:) <$> gfrom [x] <*> gfrom xs
  gfrom []       = decodingError "generic: not enough fields"

instance (GBEncodable a Dict, GBEncodable b Dict)
      => GBEncodable (a :*: b) Dict where
  {-# INLINE gto #-}
  gto (a :*: b) = gto a <> gto b

  {-# INLINE gfrom #-}
  -- Just look at this! >.<
  gfrom dict = (:*:) <$> gfrom dict <*> gfrom dict


instance (GBEncodable a e, GBEncodable b e)
      =>  GBEncodable (a :+: b) e where
  {-# INLINE gto #-}
  gto (L1 x) = gto x
  gto (R1 x) = gto x

  {-# INLINE gfrom #-}
  gfrom x = case gfrom x of
    Right lv -> return (L1 lv)
    Left  le -> do
      case gfrom x of
        Right rv -> return (R1 rv)
        Left  re -> decodingError $ "generic: both" ++ le ++ " " ++ re

gfromM1S :: forall c. Selector c
         => GBEncodable f BEncode
         => Dict -> Result (M1 i c f p)
gfromM1S dict
  | Just va <- M.lookup (BC.pack name) dict = M1 <$> gfrom va
  | otherwise = decodingError $ "generic: Selector not found " ++ show name
  where
    name = selName (error "gfromM1S: impossible" :: M1 i c f p)

instance (Selector s, GBEncodable f BEncode)
       => GBEncodable (M1 S s f) Dict where
  {-# INLINE gto #-}
  gto s @ (M1 x) = BC.pack (selName s) `M.singleton` gto x

  {-# INLINE gfrom #-}
  gfrom = gfromM1S

-- TODO DList
instance GBEncodable f BEncode
      => GBEncodable (M1 S s f) [BEncode] where
  {-# INLINE gto #-}
  gto (M1 x) = [gto x]

  gfrom [x] = M1 <$> gfrom x
  gfrom _   = decodingError "generic: empty selector"
  {-# INLINE gfrom #-}

instance (Constructor c, GBEncodable f Dict, GBEncodable f [BEncode])
       => GBEncodable (M1 C c f) BEncode where
  {-# INLINE gto #-}
  gto con @ (M1 x)
      | conIsRecord con = BDict (gto x)
      |    otherwise    = BList (gto x)

  {-# INLINE gfrom #-}
  gfrom (BDict a) = M1 <$> gfrom a
  gfrom (BList a) = M1 <$> gfrom a
  gfrom _         = decodingError "generic: Constr"

instance GBEncodable f e
      => GBEncodable (M1 D d f) e where
  {-# INLINE gto #-}
  gto (M1 x) = gto x

  {-# INLINE gfrom #-}
  gfrom x = M1 <$> gfrom x

#endif

{--------------------------------------------------------------------
  Basic instances
--------------------------------------------------------------------}

instance BEncodable BEncode where
  {-# SPECIALIZE instance BEncodable BEncode #-}
  toBEncode = id
  {-# INLINE toBEncode #-}

  fromBEncode = Right
  {-# INLINE fromBEncode #-}

instance BEncodable Int where
  {-# SPECIALIZE instance BEncodable Int #-}
  toBEncode = BInteger . fromIntegral
  {-# INLINE toBEncode #-}

  fromBEncode (BInteger i) = Right (fromIntegral i)
  fromBEncode _            = decodingError "integer"
  {-# INLINE fromBEncode #-}

instance BEncodable Bool where
  toBEncode = toBEncode . fromEnum
  {-# INLINE toBEncode #-}

  fromBEncode b = do
    i <- fromBEncode b
    case i :: Int of
      0 -> return False
      1 -> return True
      _ -> decodingError "bool"
  {-# INLINE fromBEncode #-}


instance BEncodable Integer where
  toBEncode = BInteger . fromIntegral
  {-# INLINE toBEncode #-}

  fromBEncode b = fromIntegral <$> (fromBEncode b :: Result Int)
  {-# INLINE fromBEncode #-}


instance BEncodable ByteString where
  toBEncode = BString
  {-# INLINE toBEncode #-}

  fromBEncode (BString s) = Right s
  fromBEncode _           = decodingError "string"
  {-# INLINE fromBEncode #-}


instance BEncodable Text where
  toBEncode = toBEncode . T.encodeUtf8
  {-# INLINE toBEncode #-}

  fromBEncode b = T.decodeUtf8 <$> fromBEncode b
  {-# INLINE fromBEncode #-}

instance BEncodable a => BEncodable [a] where
  {-# SPECIALIZE instance BEncodable [BEncode] #-}

  toBEncode = BList . map toBEncode
  {-# INLINE toBEncode #-}

  fromBEncode (BList xs) = mapM fromBEncode xs
  fromBEncode _          = decodingError "list"
  {-# INLINE fromBEncode #-}


instance BEncodable a => BEncodable (Map ByteString a) where
  {-# SPECIALIZE instance BEncodable (Map ByteString BEncode) #-}

  toBEncode = BDict . M.map toBEncode
  {-# INLINE toBEncode #-}

  fromBEncode (BDict d) = traverse fromBEncode d
  fromBEncode _         = decodingError "dictionary"
  {-# INLINE fromBEncode #-}

instance (Eq a, BEncodable a) => BEncodable (Set a) where
  {-# SPECIALIZE instance (Eq a, BEncodable a) => BEncodable (Set a)  #-}
  toBEncode = BList . map toBEncode . S.toAscList
  {-# INLINE toBEncode #-}

  fromBEncode (BList xs) = S.fromAscList <$> traverse fromBEncode xs
  fromBEncode _          = decodingError "Data.Set"
  {-# INLINE fromBEncode #-}

instance BEncodable () where
  {-# SPECIALIZE instance BEncodable () #-}
  toBEncode () = BList []
  {-# INLINE toBEncode #-}

  fromBEncode (BList []) = Right ()
  fromBEncode _          = decodingError "Unable to decode unit value"
  {-# INLINE fromBEncode #-}

instance (BEncodable a, BEncodable b) => BEncodable (a, b) where
  {-# SPECIALIZE instance (BEncodable a, BEncodable b) => BEncodable (a, b) #-}
  toBEncode (a, b) = BList [toBEncode a, toBEncode b]
  {-# INLINE toBEncode #-}

  fromBEncode (BList [a, b]) = (,) <$> fromBEncode a <*> fromBEncode b
  fromBEncode _              = decodingError "Unable to decode a pair."
  {-# INLINE fromBEncode #-}

instance (BEncodable a, BEncodable b, BEncodable c) => BEncodable (a, b, c) where
  {-# SPECIALIZE instance (BEncodable a, BEncodable b, BEncodable c)
                  => BEncodable (a, b, c) #-}
  {-# INLINE toBEncode #-}
  toBEncode (a, b, c) = BList [toBEncode a, toBEncode b, toBEncode c]

  fromBEncode (BList [a, b, c]) =
    (,,) <$> fromBEncode a <*> fromBEncode b <*> fromBEncode c
  fromBEncode _ = decodingError "Unable to decode a triple"
  {-# INLINE fromBEncode #-}

instance (BEncodable a, BEncodable b, BEncodable c, BEncodable d)
         => BEncodable (a, b, c, d) where
  {-# SPECIALIZE instance (BEncodable a, BEncodable b, BEncodable c, BEncodable d)
                  => BEncodable (a, b, c, d) #-}
  {-# INLINE toBEncode #-}
  toBEncode (a, b, c, d) = BList [ toBEncode a, toBEncode b
                                 , toBEncode c, toBEncode d
                                 ]

  fromBEncode (BList [a, b, c, d]) =
    (,,,) <$> fromBEncode a <*> fromBEncode b
          <*> fromBEncode c <*> fromBEncode d
  fromBEncode _ = decodingError "Unable to decode a tuple4"
  {-# INLINE fromBEncode #-}

instance (BEncodable a, BEncodable b, BEncodable c, BEncodable d, BEncodable e)
         => BEncodable (a, b, c, d, e) where
  {-# SPECIALIZE instance ( BEncodable a, BEncodable b
                          , BEncodable c, BEncodable d
                          , BEncodable e)
                  => BEncodable (a, b, c, d, e) #-}
  {-# INLINE toBEncode #-}
  toBEncode (a, b, c, d, e) = BList [ toBEncode a, toBEncode b
                                 , toBEncode c, toBEncode d
                                 , toBEncode e
                                 ]

  fromBEncode (BList [a, b, c, d, e]) =
    (,,,,) <$> fromBEncode a <*> fromBEncode b
           <*> fromBEncode c <*> fromBEncode d <*> fromBEncode e
  fromBEncode _ = decodingError "Unable to decode a tuple5"
  {-# INLINE fromBEncode #-}

instance BEncodable Version where
  {-# SPECIALIZE instance BEncodable Version #-}
  {-# INLINE toBEncode #-}
  toBEncode = toBEncode . BC.pack . showVersion

  fromBEncode (BString bs)
    | [(v, _)] <- ReadP.readP_to_S parseVersion (BC.unpack bs)
    = return v
  fromBEncode _ = decodingError "Data.Version"
  {-# INLINE fromBEncode #-}

dictAssoc :: [(ByteString, BEncode)] -> BEncode
dictAssoc = BDict . M.fromList
{-# INLINE dictAssoc #-}

{--------------------------------------------------------------------
  Building dictionaries
--------------------------------------------------------------------}

data Assoc = Required ByteString BEncode
           | Optional ByteString (Maybe BEncode)

(-->) :: BEncodable a => ByteString -> a -> Assoc
key --> val = Required key (toBEncode val)
{-# INLINE (-->) #-}

(-->?) :: BEncodable a => ByteString -> Maybe a -> Assoc
key -->? mval = Optional key (toBEncode <$> mval)
{-# INLINE (-->?) #-}

mkAssocs :: [Assoc] -> [(ByteString, BEncode)]
mkAssocs = mapMaybe unpackAssoc
  where
    unpackAssoc (Required n v)        = Just (n, v)
    unpackAssoc (Optional n (Just v)) = Just (n, v)
    unpackAssoc (Optional _ Nothing)  = Nothing

fromAssocs :: [Assoc] -> BEncode
fromAssocs = BDict . M.fromList . mkAssocs
{-# INLINE fromAssocs #-}

-- | A faster version of 'fromAssocs'. Should be used only when keys
-- are sorted by ascending.
fromAscAssocs :: [Assoc] -> BEncode
fromAscAssocs = BDict . M.fromList . mkAssocs
{-# INLINE fromAscAssocs #-}

{--------------------------------------------------------------------
  Extraction
--------------------------------------------------------------------}

reqKey :: BEncodable a => Dict -> ByteString -> Result a
reqKey d key
  | Just b <- M.lookup key d = fromBEncode b
  |        otherwise         = Left msg
  where
    msg = "required field `" ++ BC.unpack key ++ "' not found"

optKey :: BEncodable a => Dict -> ByteString -> Result (Maybe a)
optKey d key
  | Just b <- M.lookup key d
  , Right r <- fromBEncode b = return (Just r)
  | otherwise                = return Nothing

(>--) :: BEncodable a => Dict -> ByteString -> Result a
(>--) = reqKey
{-# INLINE (>--) #-}

(>--?) :: BEncodable a => Dict -> ByteString -> Result (Maybe a)
(>--?) = optKey
{-# INLINE (>--?) #-}

{--------------------------------------------------------------------
  Predicated
--------------------------------------------------------------------}

isInteger :: BEncode -> Bool
isInteger (BInteger _) = True
isInteger _            = False
{-# INLINE isInteger #-}

isString :: BEncode -> Bool
isString (BString _) = True
isString _           = False
{-# INLINE isString #-}

isList :: BEncode -> Bool
isList (BList _) = True
isList _         = False
{-# INLINE isList #-}

isDict :: BEncode -> Bool
isDict (BList _) = True
isDict _         = False
{-# INLINE isDict #-}

{--------------------------------------------------------------------
  Encoding
--------------------------------------------------------------------}

encode :: BEncode -> Lazy.ByteString
encode = B.toLazyByteString . builder

decode :: ByteString -> Result BEncode
decode = P.parseOnly parser

decoded :: BEncodable a => ByteString -> Result a
decoded = decode >=> fromBEncode

encoded :: BEncodable a => a -> Lazy.ByteString
encoded = encode . toBEncode

{--------------------------------------------------------------------
  Internals
--------------------------------------------------------------------}

builder :: BEncode -> B.Builder
builder = go
    where
      go (BInteger i) = B.word8 (c2w 'i') <>
                        ASCII.int64Dec i <>
                        B.word8 (c2w 'e')
      go (BString  s) = buildString s
      go (BList    l) = B.word8 (c2w 'l') <>
                        foldMap go l <>
                        B.word8 (c2w 'e')
      go (BDict    d) = B.word8 (c2w 'd') <>
                        foldMap mkKV (M.toAscList d) <>
                        B.word8 (c2w 'e')
          where
            mkKV (k, v) = buildString k <> go v

      buildString s = ASCII.intDec (B.length s) <>
                      B.word8 (c2w ':') <>
                      B.byteString s
      {-# INLINE buildString #-}

-- | TODO try to replace peekChar with something else
parser :: Parser BEncode
parser = valueP
  where
    valueP = do
      mc <- P.peekChar
      case mc of
        Nothing -> fail "end of input"
        Just c  ->
            case c of
              -- if we have digit it always should be string length
              di | di <= '9' -> BString <$> stringP
              'i' -> P.anyChar *> ((BInteger <$> integerP) <* P.anyChar)
              'l' -> P.anyChar *> ((BList    <$> listBody) <* P.anyChar)
              'd' -> do
                     P.anyChar
                     (BDict . M.fromDistinctAscList <$>
                          many ((,) <$> stringP <*> valueP))
                       <* P.anyChar
              t   -> fail ("bencode unknown tag: " ++ [t])

    listBody = do
      c <- P.peekChar
      case c of
        Just 'e' -> return []
        _        -> (:) <$> valueP <*> listBody

    stringP :: Parser ByteString
    stringP = do
      n <- P.decimal :: Parser Int
      P.char ':'
      P.take n
    {-# INLINE stringP #-}

    integerP :: Parser Int64
    integerP = do
      c <- P.peekChar
      case c of
        Just '-' -> do
          P.anyChar
          negate <$> P.decimal
        _        ->  P.decimal
    {-# INLINE integerP #-}

{--------------------------------------------------------------------
  Pretty Printing
--------------------------------------------------------------------}

printPretty :: BEncode -> IO ()
printPretty = print . ppBEncode

ppBS :: ByteString -> Doc
ppBS = text . map w2c . B.unpack

ppBEncode :: BEncode -> Doc
ppBEncode (BInteger i) = int $ fromIntegral i
ppBEncode (BString  s) = ppBS s
ppBEncode (BList    l) = brackets $ hsep $ punctuate comma $ map ppBEncode l
ppBEncode (BDict    d)
    = braces $ vcat $ punctuate comma $ map ppKV $ M.toAscList d
  where
    ppKV (k, v) = ppBS k <+> colon <+> ppBEncode v

{--------------------------------------------------------------------
  Other instances
--------------------------------------------------------------------}

instance BEncodable Word8 where
  {-# SPECIALIZE instance BEncodable Word8 #-}
  toBEncode = toBEncode . (fromIntegral :: Word8 -> Word64)
  {-# INLINE toBEncode #-}
  fromBEncode b = (fromIntegral :: Word64 -> Word8) <$> fromBEncode b
  {-# INLINE fromBEncode #-}

instance BEncodable Word16 where
  {-# SPECIALIZE instance BEncodable Word16 #-}
  toBEncode = toBEncode . (fromIntegral :: Word16 -> Word64)
  {-# INLINE toBEncode #-}
  fromBEncode b = (fromIntegral :: Word64 -> Word16) <$> fromBEncode b
  {-# INLINE fromBEncode #-}

instance BEncodable Word32 where
  {-# SPECIALIZE instance BEncodable Word32 #-}
  toBEncode = toBEncode . (fromIntegral :: Word32 -> Word64)
  {-# INLINE toBEncode #-}
  fromBEncode b = (fromIntegral :: Word64 -> Word32) <$> fromBEncode b
  {-# INLINE fromBEncode #-}

instance BEncodable Word64 where
  {-# SPECIALIZE instance BEncodable Word64 #-}
  toBEncode = toBEncode . (fromIntegral :: Word64 -> Int)
  {-# INLINE toBEncode #-}
  fromBEncode b = (fromIntegral :: Int -> Word64) <$> fromBEncode b
  {-# INLINE fromBEncode #-}

instance BEncodable Word where -- TODO: make platform independent
  {-# SPECIALIZE instance BEncodable Word #-}
  toBEncode = toBEncode . (fromIntegral :: Word -> Int)
  {-# INLINE toBEncode #-}
  fromBEncode b = (fromIntegral :: Int -> Word) <$> fromBEncode b
  {-# INLINE fromBEncode #-}

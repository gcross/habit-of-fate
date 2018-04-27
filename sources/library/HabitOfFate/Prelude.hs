{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Prelude
  (
  -- Modules
    module Prelude
  , module Control.Applicative
  , module Control.Arrow
  , module Control.Category
  , module Control.Lens
  , module Control.Monad
  , module Control.Monad.Except
  , module Control.Monad.Fail
  , module Control.Monad.Reader
  , module Control.Monad.State.Strict
  , module Control.Monad.Writer.Strict
  , module Data.Bool
  , module Data.ByteString
  , module Data.Containers
  , module Data.Default
  , module Data.Either
  , module Data.Foldable
  , module Data.Function
  , module Data.Functor
  , module Data.HashMap.Strict
  , module Data.List
  , module Data.Map.Strict
  , module Data.Maybe
  , module Data.Monoid
  , module Data.MonoTraversable
  , module Data.Sequence
  , module Data.Sequences
  , module Data.Set
  , module Data.String.Interpolate
  , module Data.Text
  , module Data.Text.Lens
  , module Data.Traversable
  , module Debug.Trace
  , module Flow
  , module Text.Printf
  , module Text.Read
  , module System.FilePath
  -- Operators
  , (⊕)
  , (⊕~)
  , (⊕=)
  , (∈)
  , (∉)
  , (≤)
  , (≥)
  , (⊢)
  , (⊣)
  , identity
  , rewords
  , showText
  , spy
  , swap
  ) where

import Prelude
  ( Bool(..)
  , Bounded(..)
  , Char
  , Double
  , Enum(..)
  , Eq(..)
  , Float
  , Floating(..)
  , Fractional(..)
  , Int
  , Integer
  , Integral(..)
  , IO
  , Num(..)
  , Ord(..)
  , Rational
  , Read(..)
  , Real(..)
  , RealFloat(..)
  , RealFrac(..)
  , Show(..)
  , String
  , (^)
  , (^^)
  , curry
  , error
  , even
  , fromIntegral
  , fst
  , gcd
  , lcm
  , map
  , odd
  , read
  , realToFrac
  , snd
  , subtract
  , uncurry
  , zip
  )

import Control.Applicative hiding (many)

import Control.Arrow hiding (loop)

import Control.Category

import Control.Lens hiding ((|>), (<|))

import Control.Monad
  hiding
    ( fail
    )

import Control.Monad.Except
  hiding
    ( fail
    , filterM
    , replicateM
    )

import Control.Monad.Fail

import Control.Monad.Reader
  hiding
    ( fail
    , filterM
    , reader
    , replicateM
    )

import Control.Monad.State.Strict
  hiding
    ( fail
    , filterM
    , replicateM
    )

import Control.Monad.Writer.Strict
  hiding
    ( fail
    , filterM
    , replicateM
    , writer
    )

import Data.Bool

import Data.ByteString (ByteString)

import Data.Containers

import Data.Default

import Data.Either

import Data.Foldable

import Data.Function hiding ((.), id)

import Data.Functor

import Data.HashMap.Strict (HashMap)

import Data.List
  ( findIndex
  , findIndices
  , intercalate
  , intersperse
  , length
  , nub
  , reverse
  )

import Data.Map.Strict (Map)

import Data.Maybe hiding (catMaybes)

import Data.Monoid

import Data.MonoTraversable

import Data.Sequence (Seq)

import Data.Sequences
  ( break
  , decodeUtf8
  , drop
  , dropWhile
  , encodeUtf8
  , filter
  , fromList
  , lines
  , pack
  , repack
  , replicate
  , singleton
  , takeWhile
  , unlines
  , unpack
  , unwords
  , words
  )

import Data.Set (Set)

import Data.String.Interpolate

import Data.Text (Text)

import Data.Text.Lens

import Data.Traversable

import Debug.Trace

import Flow hiding ((.>), (<.))

import System.FilePath (FilePath)

import Text.Parsec

import Text.Printf

import Text.Read (readEither, readMaybe)

instance MonadFail (ParsecT s u m) where
  fail = parserFail

instance MonadFail (Either String) where
  fail = Left

infixr 6 ⊕
(⊕) ∷ Monoid m ⇒ m → m → m
(⊕) = mappend
{-# INLINE (⊕) #-}

infixr 4 ⊕~
(⊕~) ∷ Monoid α ⇒ ASetter s t α α → α → s → t
(⊕~) = (<>~)
{-# INLINE (⊕~) #-}

infixr 4 ⊕=
(⊕=) ∷ (MonadState s m, Monoid α) => ASetter' s α -> α -> m ()
(⊕=) = (<>=)
{-# INLINE (⊕=) #-}

infixr 6 ∈
(∈) ∷ Eq α ⇒ α → [α] → Bool
(∈) = elem
{-# INLINE (∈)  #-}

infixr 6 ∉
(∉) ∷ Eq α ⇒ α → [α] → Bool
(∉) x xs = not (x ∈ xs)
{-# INLINE (∉)  #-}

infix  4 ≤
(≤) ∷ Ord α ⇒ α → α → Bool
(≤) = (<=)

infix  4 ≥
(≥) ∷ Ord α ⇒ α → α → Bool
(≥) = (>=)

infixr  5 ⊢
(⊢) = Control.Lens.snoc

infixr  5 ⊣
(⊣) = Control.Lens.cons

identity ∷ α → α
identity = id

rewords = words >>> unwords

showText ∷ Show α ⇒ α → Text
showText = show >>> view packed

spy ∷ Show α ⇒ String → α → α
spy label value = trace (label ⊕ ": " ⊕ show value) value

swap ∷ (α,β) → (β,α)
swap (x,y) = (y,x)

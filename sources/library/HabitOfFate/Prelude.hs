{-
    Habit of Fate, a game to incentivize habit formation.
    Copyright (C) 2017 Gregory Crosswhite

    This program is free software: you can redistribute it and/or modify
    it under version 3 of the terms of the GNU Affero General Public License.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
-}

{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TypeFamilies #-}
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
  , module Data.HashSet
  , module Data.List
  , module Data.Map.Strict
  , module Data.Maybe
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
  -- Classes
  , Monoid(..)
  , Semigroup(..)
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
  , allSpaces
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
  , seq
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

import Data.HashSet (HashSet)

import Data.List
  ( findIndex
  , findIndices
  , intercalate
  , intersperse
  , group
  , groupBy
  , length
  , nub
  )

import Data.Map.Strict (Map)

import Data.Maybe

import Data.MonoTraversable hiding (Element)
import qualified Data.MonoTraversable as MonoTraversable

import Data.Semigroup

import Data.Sequence (Seq)

import Data.Sequences
  ( break
  , decodeUtf8
  , delete
  , drop
  , dropEnd
  , dropWhile
  , encodeUtf8
  , filter
  , fromList
  , fromStrict
  , isSuffixOf
  , lines
  , pack
  , repack
  , replicate
  , reverse
  , singleton
  , sort
  , stripPrefix
  , stripSuffix
  , take
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

import Text.Printf

import Text.Read (readEither, readMaybe)

instance MonadFail (Either String) where
  fail = Left

infixr 6 ⊕
(⊕) ∷ Semigroup m ⇒ m → m → m
(⊕) = (<>)
{-# INLINE (⊕) #-}

infixr 4 ⊕~
(⊕~) ∷ Monoid α ⇒ ASetter s t α α → α → s → t
(⊕~) = (<>~)
{-# INLINE (⊕~) #-}

infixr 4 ⊕=
(⊕=) ∷ (MonadState s m, Monoid α) ⇒ ASetter' s α → α → m ()
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

infixr 5 ⊢
(⊢) = Control.Lens.snoc

infixr 5 ⊣
(⊣) = Control.Lens.cons

allSpaces ∷ (MonoFoldable α, MonoTraversable.Element α ~ Char) ⇒ α → Bool
allSpaces = oall (∈ " \t\r\n")

identity ∷ α → α
identity = id

rewords = words >>> unwords

showText ∷ Show α ⇒ α → Text
showText = show >>> view packed

spy ∷ Show α ⇒ String → α → α
spy label value = trace (label ⊕ ": " ⊕ show value) value

swap ∷ (α,β) → (β,α)
swap (x,y) = (y,x)

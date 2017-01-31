{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnicodeSyntax #-}

import HabitOfFate.Prelude hiding (elements)

import Control.Concurrent
import Control.Lens.Extras
import qualified Data.Map as Map
import Network.Wai.Handler.Warp
import System.Directory
import System.FilePath
import System.IO
import System.Log
import System.Log.Handler.Simple
import System.Log.Logger
import System.Random
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck
import qualified Test.Tasty.SmallCheck as S
import Test.QuickCheck
import Test.SmallCheck.Series

import Debug.Trace

import HabitOfFate.App.Server
import HabitOfFate.Client
import HabitOfFate.Habit
import HabitOfFate.Story

instance Arbitrary Text where
  arbitrary = pack <$> arbitrary

instance Arbitrary Color where
  arbitrary = elements [Red, Green, Blue]

instance Monad m ⇒ Serial m Color where

instance Arbitrary Style where
  arbitrary = oneof
    [ return Bold
    , return Underline
    , Color <$> arbitrary
    , return Introduce
    ]

instance Monad m ⇒ Serial m Style where

instance Arbitrary α ⇒ Arbitrary (GenParagraph α) where
  arbitrary = sized $ \n →
    if n <= 1
      then Text_ <$> arbitrary
      else oneof
        [ Style <$> arbitrary <*> resize (n-1) arbitrary
        , Merged <$> (do
            nc ← choose (1,n)
            fromList <$> vectorOf nc (resize (n `div` nc) arbitrary)
          )
        , Text_ <$> arbitrary
        ]
  shrink (Style _ child) = [child]
  shrink (Merged children) = toList children
  shrink (Text_ _) = []

instance Arbitrary α ⇒ Arbitrary (GenEvent α) where
  arbitrary = GenEvent <$> arbitrary
  shrink = fmap GenEvent ∘ shrink ∘ unwrapGenEvent

instance Arbitrary α ⇒ Arbitrary (GenQuest α) where
  arbitrary = GenQuest <$> arbitrary
  shrink = fmap GenQuest ∘ shrink ∘ unwrapGenQuest

instance Arbitrary α ⇒ Arbitrary (GenStory α) where
  arbitrary = GenStory <$> arbitrary
  shrink = fmap GenStory ∘ shrink ∘ unwrapGenStory

instance (Monad m, Serial m α) ⇒ Serial m (Seq α) where
  series = fromList <$> series

instance Monad m ⇒ Serial m Text where
  series = pack <$> series

instance Monad m ⇒ Serial m SubText where

instance (Monad m, Serial m α) ⇒ Serial m (GenParagraph α) where

instance (Monad m, Serial m α) ⇒ Serial m (GenEvent α) where

instance (Monad m, Serial m α) ⇒ Serial m (GenQuest α) where

instance (Monad m, Serial m α) ⇒ Serial m (GenStory α) where

header ∷ String → String
header header = replicate left_dash_count '-' ⊕ " " ⊕ header ⊕ " " ⊕ replicate right_dash_count '-'
  where
    dash_count = 80 - 2 - length header
    right_dash_count = dash_count `div` 2
    left_dash_count = dash_count - right_dash_count

serverTestCase ∷ String → (Client ()) → TestTree
serverTestCase name action = testCase name $ do
  debugM "Test" $ header name
  tempdir ← getTemporaryDirectory
  filepath ← (tempdir </>) ∘ ("test-" ⊕) <$> replicateM 8 (randomRIO ('A','z'))
  withApplication (makeApp filepath) (runReaderT action ∘ ServerInfo "localhost")

initialize = do
  doesFileExist "test.log" >>= flip when (removeFile "test.log")
  file_handler ← fileHandler "test.log" DEBUG
  updateGlobalLogger rootLoggerName $
    setLevel DEBUG
    ∘
    setHandlers [file_handler]

test_habit = Habit "name" 1 1
test_habit_2 = Habit "test" 2 2

originalFromSubParagraph ∷ SubParagraph → Text
originalFromSubParagraph =
  rewords
  ∘
  foldMap (
    \case
      Literal t → t
      Key k → "{" ⊕ k ⊕ "}"
  )

originalFromSubEvent ∷ SubEvent → Text
originalFromSubEvent =
  mconcat
  ∘
  intersperse "\n"
  ∘
  map originalFromSubParagraph
  ∘
  unwrapGenEvent

main = initialize >> (defaultMain $ testGroup "All Tests"
  [ testGroup "HabitOfFate.App.Server"
    [ serverTestCase "Get all habits when none exist" $
        fetchHabits
        >>=
        liftIO ∘ (@?= Map.empty)
    , serverTestCase "Get a particular habit when none exist" $
        fetchHabit (read "730e9d4a-7d72-4a28-a19b-0bcc621c1506")
        >>=
        liftIO ∘ (@?= Nothing)
    , serverTestCase "Create and fetch a habit" $
        createHabit test_habit
        >>=
        fetchHabit
        >>=
        liftIO ∘ (@?= Just test_habit)
    , serverTestCase "Create a habit and fetch all habits" $ do
        uuid ← createHabit test_habit
        fetchHabits >>= liftIO ∘ (@?= Map.singleton uuid test_habit)
    , serverTestCase "Create a habit, delete it, and fetch all habits" $ do
        uuid ← createHabit test_habit
        deleteHabit uuid
        fetchHabits >>= liftIO ∘ (@?= Map.empty)
    , serverTestCase "Create a habit, replace it, and fetch all habits" $ do
        uuid ← createHabit test_habit
        replaceHabit uuid test_habit_2
        fetchHabits >>= liftIO ∘ (@?= Map.singleton uuid test_habit_2)
    , serverTestCase "Mark habits." $ do
        uuid_1 ← createHabit test_habit
        uuid_2 ← createHabit test_habit_2
        markHabits [uuid_1] [uuid_2]
        getCredits >>= liftIO ∘ (@?= (1,2))
    ]
  , testGroup "HabitOfFate.Story"
    [ testGroup "s"
      [ testCase "just a substitution" $ length [s|{test}|] @?= 1
      , testCase "single story plain text" $
          length [s|line1|] @?= 1
      , testCase "2 stories: 1 empty, 1 non-empty" $
          length [s|line1
                    =
                   |] @?= 1
      , testCase "2 stories: both non-empty" $
          length [s|line1
                    =
                    line2
                   |] @?= 2
      , testCase "single literal letter round trip" $
          "x" @?= originalFromSubEvent [s_fixed|x|]
      , testCase "single key letter round trip" $
          "{x}" @?= originalFromSubEvent [s_fixed|{x}|]
      , testCase "two keys separated by a space" $
          "{x} {y}" @?= originalFromSubEvent [s_fixed|{x} {y}|]
      ]
    , testGroup "makeSubstitutor"
      [ testGroup "name" $
          [ testCase "gendered"
              ∘
              (Right "Y" @=?)
              ∘
              (_Right %~ textFromParagraph)
              $
              makeSubstitutor
                (flip lookup [("X", Gendered "Y" (error "should not be using the gender"))])
                (const Nothing)
                "X"
          , testCase "neutered"
              ∘
              (Right "Y" @=?)
              ∘
              (_Right %~ textFromParagraph)
              $
              makeSubstitutor
                (const Nothing)
                (flip lookup [("X","Y")])
                "X"
          ]
      ]
    , testGroup "substitute"
        [ testCase "single letter" $ do
            let GenEvent [subparagraph] = [s_fixed|{x}|]
            Right "X" @=? (
              rewords
              ∘
              textFromParagraph
              <$>
              substitute (const ∘ Right ∘ Text_ $ "X") subparagraph
             )
        , testCase "two keys separated by a space" $ do
            let GenEvent [subparagraph] = [s_fixed|{x} {y}|]
            Right "X Y" @=? (
              rewords
              ∘
              textFromParagraph
              <$>
              substitute (
                  fmap Text_
                  ∘
                  \case {"x" → Right "X"; "y" → Right "Y"; _ → Left "not found"}
              ) subparagraph
             )
        ]
    , testGroup "round-trip"
      [ testGroup "Paragraph -> [Node] -> Paragraph"
        [ S.testProperty "SmallCheck" $ \story →
            let xml_text = renderStoryToText story
                round_trip_story = parseStoryFromText xml_text
                round_trip_xml_text = renderStoryToText <$> round_trip_story
            in if round_trip_xml_text == Right xml_text
                  then Right ("" ∷ String)
                  else Left $
                    unlines
                      ["ORIGINAL STORY:"
                      ,"    Right " ⊕ show (storyToLists story)
                      ,"ROUND-TRIP STORY:"
                      ,"    " ⊕ show (fmap storyToLists round_trip_story)
                      ,"ORIGINAL XML:"
                      ,"    Right " ⊕ show xml_text
                      ,"ROUND-TRIP XML:"
                      ,"    " ⊕ show round_trip_xml_text
                      ]
        , localOption (QuickCheckMaxSize 20)
          $
          testProperty "QuickCheck" $ \story →
            let xml_text = renderStoryToText story
                round_trip_story = parseStoryFromText xml_text
                round_trip_xml_text = renderStoryToText <$> round_trip_story
            in counterexample (
                unlines
                  ["ORIGINAL STORY:"
                  ,"    Right " ⊕ show (storyToLists story)
                  ,"ROUND-TRIP STORY:"
                  ,"    " ⊕ show (fmap storyToLists round_trip_story)
                  ,"ORIGINAL XML:"
                  ,"    Right " ⊕ show xml_text
                  ,"ROUND-TRIP XML:"
                  ,"    " ⊕ show round_trip_xml_text
                  ]
              )
              $
              round_trip_xml_text == Right xml_text
        ]
      ]
    ]
  ]
 )

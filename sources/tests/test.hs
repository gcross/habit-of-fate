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
import qualified Data.UUID as UUID
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

import HabitOfFate.App.Server
import HabitOfFate.Client
import HabitOfFate.Credits
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
    dash_count = 80 - 2 - olength header
    right_dash_count = dash_count `div` 2
    left_dash_count = dash_count - right_dash_count

serverTestCase ∷ String → (Client ()) → TestTree
serverTestCase name action = testCase name $ do
  debugM "Test" $ header name
  tempdir ← getTemporaryDirectory
  filepath ← (tempdir </>) ∘ ("test-" ⊕) <$> replicateM 8 (randomRIO ('A','z'))
  withApplication
    (makeApp filepath)
    (\port → newServerInfo Testing "localhost" port >>= runReaderT action)

initialize = do
  doesFileExist "test.log" >>= flip when (removeFile "test.log")
  file_handler ← fileHandler "test.log" DEBUG
  updateGlobalLogger rootLoggerName $
    setLevel DEBUG
    ∘
    setHandlers [file_handler]

test_habit = Habit "name" (Credits 1 1)
test_habit_2 = Habit "test" (Credits 2 2)

test_habit_id = read "95bef3cf-9031-4f64-8458-884aa6781563"
test_habit_id_2 = read "9e801a68-4288-4a23-8779-aa68f94991f9"

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
    , serverTestCase "Create and fetch a habit" $ do
        putHabit test_habit_id test_habit
        fetchHabit test_habit_id >>= liftIO ∘ (@?= Just test_habit)
    , serverTestCase "Create a habit and fetch all habits" $ do
        putHabit test_habit_id test_habit
        fetchHabits >>= liftIO ∘ (@?= Map.singleton test_habit_id test_habit)
    , serverTestCase "Create a habit, delete it, and fetch all habits" $ do
        putHabit test_habit_id test_habit
        deleteHabit test_habit_id
        fetchHabits >>= liftIO ∘ (@?= Map.empty)
    , serverTestCase "Create a habit, replace it, and fetch all habits" $ do
        putHabit test_habit_id test_habit
        putHabit test_habit_id test_habit_2
        fetchHabits >>= liftIO ∘ (@?= Map.singleton test_habit_id test_habit_2)
    , serverTestCase "Mark habits." $ do
        putHabit test_habit_id test_habit
        putHabit test_habit_id_2 test_habit_2
        markHabits [test_habit_id] [test_habit_id_2]
        getCredits >>= liftIO ∘ (@?= Credits 1 2)
    ]
  , testGroup "HabitOfFate.Story"
    [ testGroup "s"
      [ testCase "just a substitution" $ olength [s|{test}|] @?= 1
      , testCase "single story plain text" $
          olength [s|line1|] @?= 1
      , testCase "2 stories: 1 empty, 1 non-empty" $
          olength [s|line1
                    =
                   |] @?= 1
      , testCase "2 stories: both non-empty" $
          olength [s|line1
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
        , testCase "paragraph" $ do
            let GenEvent [subparagraph] = [s_fixed|
The last thing in the world that <introduce>{Susie}</introduce> wanted to do was
to wander alone in the Wicked Forest at night, but {her|pos} {son}, little
<introduce>{Tommy}</introduce>, was sick and would not live through the night
unless {Susie} could find <introduce>{an Illsbane}</introduce> plant. It is a
hopeless task, but {she} has no other choice.
|]
            Right "The last thing in the world that Mark wanted to do was to wander alone in the Wicked Forest at night, but his daughter, little Sally, was sick and would not live through the night unless Mark could find a Wolfsbane plant. It is a hopeless task, but he has no other choice." @=? (
              rewords
              ∘
              textFromParagraph
              <$>
              substitute (
                  fmap Text_
                  ∘
                  (\case
                    "Susie" → Right "Mark"
                    "her|pos" → Right "his"
                    "son" → Right "daughter"
                    "Tommy" → Right "Sally"
                    "an Illsbane" → Right "a Wolfsbane"
                    "she" → Right "he"
                    other → Left ("not found: " ⊕ show other)
                  )
              ) subparagraph
             )
        ]
    , testGroup "rendering"
        [ testCase "three Text_, middle space" $
            (renderStoryToText $ GenStory [GenQuest [GenEvent ["X Y"]]])
            @?=
            (renderStoryToText $ GenStory [GenQuest [GenEvent [mconcat ["X", " ", "Y"]]]])
        ]
    , testGroup "round-trip"
      [ testGroup "Paragraph -> [Node] -> Paragraph" $
          let doTest story =
                ( is _Right double_round_trip_xml_text
                  &&
                  double_round_trip_xml_text == round_trip_xml_text
                , message
                )
                where
                  xml_text = renderStoryToText story
                  round_trip_story = parseStoryFromText xml_text
                  round_trip_xml_text = renderStoryToText <$> round_trip_story
                  double_round_trip_story = round_trip_xml_text >>= parseStoryFromText
                  double_round_trip_xml_text = renderStoryToText <$> double_round_trip_story
                  message = unlines
                    ["ORIGINAL STORY:"
                    ,"    Right " ⊕ show (storyToLists story)
                    ,"ROUND-TRIP STORY:"
                    ,"    " ⊕ show (fmap storyToLists round_trip_story)
                    ,"DOUBLE ROUND-TRIP STORY:"
                    ,"    " ⊕ show (fmap storyToLists double_round_trip_story)
                    ,"ORIGINAL XML:"
                    ,"    Right " ⊕ show xml_text
                    ,"ROUND-TRIP XML:"
                    ,"    " ⊕ show round_trip_xml_text
                    ,"DOUBLE ROUND-TRIP XML:"
                    ,"    " ⊕ show double_round_trip_xml_text
                    ]
          in
          [ S.testProperty "SmallCheck" $ \story →
              let (result, message) = doTest story
              in if result then Right ("" ∷ String) else Left message
          , localOption (QuickCheckMaxSize 20)
            $
            testProperty "QuickCheck" $ \story →
              let (result, message) = doTest story
              in counterexample message result
          ]
      ]
    ]
  ]
 )

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

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Server.Requests.Web.EditAndDeleteHabit (handler) where

import HabitOfFate.Prelude

import Data.Maybe (catMaybes)
import qualified Data.Text.Lazy as Lazy
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Time.LocalTime (LocalTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Network.HTTP.Types.Status (ok200, temporaryRedirect307)
import Text.Blaze.Html5 ((!), toHtml)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Web.Scotty (Parsable, ScottyM)
import qualified Web.Scotty as Scotty

import HabitOfFate.Data.Account
import HabitOfFate.Data.Habit
import HabitOfFate.Data.ItemsSequence
import HabitOfFate.Data.InputHabit
import HabitOfFate.Data.Repeated
import HabitOfFate.Data.Scale
import HabitOfFate.Data.Tagged
import HabitOfFate.Server.Common
import HabitOfFate.Server.Transaction

data DeletionMode = NoDeletion | DeletionAvailable | ConfirmDeletion

renderHabitPage ∷ UUID → Seq Text → DeletionMode → InputHabit → Transaction TransactionResult
renderHabitPage habit_id error_messages deletion_mode input_habit = do
  groups ← use groups_
  renderTopOnlyPageResult "Habit of Fate - Editing a Habit" ["edit"] ["edit"] (Just "updateEnabled();") ok200 >>> pure $ do
    let clickRadio, clickCheckbox ∷ Text → H.AttributeValue
        clickRadio name = H.toValue $ "document.getElementById(\"" ⊕ name ⊕ "_radio\").click()"
        clickCheckbox name = H.toValue $ "document.getElementById(\"" ⊕ name ⊕ "_checkbox\").click()"

        checkedIf ∷ Bool → H.Html → H.Html
        checkedIf = bool identity (! A.checked "checked")

        extractValue ∷ Getter InputHabit (Maybe α) → α → α
        extractValue input_getter_ default_value =
          input_habit
            |> (^. input_getter_)
            |> fromMaybe default_value

        inputValue ∷ H.ToValue α ⇒ Getter InputHabit (Maybe α) → α → H.Attribute
        inputValue input_getter_ default_value =
          extractValue input_getter_ default_value
            |> H.toValue
            |> A.value

        format_time_ = to (fmap formatLocalTime)

    H.form ! A.method "post" $ do
      H.div ! A.class_ "fields" $ do
        -- Name
        H.div ! A.class_ "label" $ H.toHtml ("Name:" ∷ Text)
        H.div $
          H.input
            ! A.type_ "text"
            ! A.name "name"
            ! A.required "true"
            ! A.size "60"
            ! A.id "name_input"
            ! inputValue input_name_ ""

        -- Template for Difficulty and Importance
        let generateScaleEntry ∷ H.AttributeValue → Text → Lens' InputHabit (Maybe Scale) → H.Html
            generateScaleEntry name label value_lens_ = do
              H.div
                ! A.class_ "label"
                $ H.toHtml label
              H.select
                ! A.name name
                ! A.required "true"
                $ (flip foldMap scales $ \scale →
                    let opt = H.option ! A.value (scale |> show |> H.toValue)
                    in (if scale == (input_habit |> (^. value_lens_) |> fromMaybe def)
                        then opt ! A.selected "selected"
                        else opt
                       ) $ H.toHtml (displayScale scale)
                  )

        generateScaleEntry "difficulty" "Difficulty:" input_difficulty_
        generateScaleEntry "importance" "Importance:" input_importance_

        H.div ! A.class_ "top_aligned_label" $ H.toHtml ("Frequency:" ∷ Text)

        let input_frequency = input_habit |> (^. input_frequency_) |> fromMaybe InputIndefinite

        H.div ! A.id "frequency_input" $ do
          H.div ! A.class_ "row" $ do
            H.input
              ! A.class_ "radio"
              ! A.type_ "radio"
              ! A.name "frequency"
              ! A.value "Indefinite"
              ! A.id "indefinite_radio"
              ! A.onclick "updateEnabled()"
              & checkedIf (input_frequency == InputIndefinite)
            H.div
              ! A.onclick (clickRadio "indefinite")
              $ H.toHtml ("Indefinite" ∷ Text)

          H.div ! A.class_ "row row_spacer" $ do
            H.input
              ! A.class_ "radio"
              ! A.type_ "radio"
              ! A.name "frequency"
              ! A.value "Once"
              ! A.id "once_radio"
              ! A.onclick "updateEnabled()"
              & checkedIf (input_frequency == InputOnce)
            H.div ! A.class_ "row vertically_centered" $ do
              H.div
                ! A.class_ "label"
                ! A.onclick (clickRadio "once")
                $ H.toHtml ("Once" ∷ Text)
              H.div ! A.class_ "row right10px" $ do
                H.input
                  ! A.class_ "checkbox once_control"
                  ! A.id "once_has_deadline"
                  ! A.type_ "checkbox"
                  ! A.name "once_has_deadline"
                  ! A.onclick "updateNextDeadlineControlBasedOnOnceHasDeadline()"
                  & checkedIf (input_habit ^. input_once_has_deadline_)
                H.div
                  ! A.class_ "once_control"
                  $ H.toHtml ("With Deadline" ∷ Text)

          H.div ! A.class_ "row row_spacer" $ do
            H.input
              ! A.class_ "radio"
              ! A.type_ "radio"
              ! A.name "frequency"
              ! A.value "Repeated"
              ! A.id "repeated_radio"
              ! A.onclick "updateEnabled()"
              & checkedIf (input_frequency == InputRepeated)
            H.div
              ! A.onclick (clickRadio "repeated")
              $ H.toHtml ("Repeated" ∷ Text)

          H.div ! A.class_ "indent" $ do
            let createBasicRepeatedControl ∷ Text → Text → Text → InputRepeated → Lens' InputHabit (Maybe Int) → H.Html
                createBasicRepeatedControl label lowercase_label plural repeated_value period_lens_ =
                  H.div ! A.class_ "row_spacer" $ do
                    H.div ! A.class_ "row" $ do
                      H.input
                        ! A.class_ "radio repeated_control"
                        ! A.id (H.toValue $ lowercase_label ⊕ "_radio")
                        ! A.type_ "radio"
                        ! A.name "repeated"
                        ! A.value (H.toValue label)
                        ! A.onclick "updateRepeated()"
                        & checkedIf (fromMaybe InputDaily (input_habit ^. input_repeated_) == repeated_value)
                      H.div
                        ! A.class_ "label repeated_control"
                        ! A.onclick (clickRadio lowercase_label)
                        $ H.toHtml label
                    H.div ! A.class_ "indent" $ do
                      H.div ! A.class_ "row row_spacer" $ do
                        H.div
                          ! A.class_ (H.toValue $ "right5px " ⊕ lowercase_label ⊕ "_control repeated_control")
                          $ H.toHtml ("Every" ∷ Text)
                        H.input
                          ! A.class_ (H.toValue $ "period right5px " ⊕ lowercase_label ⊕ "_control repeated_control")
                          ! A.type_ "number"
                          ! A.name (H.toValue $ lowercase_label ⊕ "_period")
                          ! A.size "2"
                          ! inputValue period_lens_ 1
                        H.div
                          ! A.class_ (H.toValue $ lowercase_label ⊕ "_control repeated_control")
                          $ H.toHtml (plural ⊕ "." ∷ Text)

            createBasicRepeatedControl "Daily" "daily" "days" InputDaily input_daily_period_
            createBasicRepeatedControl "Weekly" "weekly" "weeks" InputWeekly input_weekly_period_

            H.div ! A.class_ "indent row row_spacer" $ do
              mconcat
                [ H.div ! A.class_ "column right10px" $ do
                    H.input
                      ! A.class_ (H.toValue ("weekly_control repeated_control" ∷ Text))
                      ! A.id (H.toValue $ weekday_name ⊕ "_checkbox")
                      ! A.type_ "checkbox"
                      ! A.name (H.toValue weekday_name)
                      & checkedIf (input_habit ^# input_days_to_repeat_ . weekday_lens_)
                    H.div
                      ! A.class_ "weekly_control repeated_control"
                      ! A.onclick (clickCheckbox (Lazy.toStrict weekday_name))
                      $ H.toHtml weekday_abbrev
                | (weekday_abbrev, weekday_name, weekday_lens_) ← weekdays
                ]

          H.div ! A.class_ "indent row double_row_spacer" $ do
            H.div
              ! A.class_ "label repeated_control"
              $ H.toHtml ("Days to Keep:" ∷ Text)

            H.input
              ! A.class_ "period right5px repeated_control"
              ! A.type_ "number"
              ! A.name (H.toValue ("days_to_keep" ∷ Text))
              ! A.size "2"
              ! inputValue input_days_to_keep_ 3

            H.div $ mconcat
              [ H.div ! A.class_ "row" $ do
                  H.input
                    ! A.class_ "radio repeated_control"
                    ! A.id (H.toValue $ value ⊕ "_radio")
                    ! A.type_ "radio"
                    ! A.name "days_to_keep_mode"
                    ! A.value (H.toValue value)
                    & checkedIf (extractValue input_days_to_keep_mode_ InputKeepNumberOfDays == input_value)
                  H.div
                    ! A.class_ "label repeated_control"
                    ! A.onclick (clickRadio value)
                    $ H.toHtml label
              | (input_value, value ∷ Text, label ∷ Text) ←
                  [ ( InputKeepNumberOfDays, "KeepNumberOfDays", "in total" )
                  , ( InputKeepDaysInPast, "KeepDaysInPast", "into the past" )
                  ]
              ]

        H.div ! A.class_ "label next_deadline_control" $ H.toHtml ("(Next) Deadline:" ∷ Text)

        H.div $
          H.input
            ! A.class_ "next_deadline_control"
            ! A.type_ "datetime-local"
            ! A.name "next_deadline"
            ! inputValue (input_next_deadline_ . format_time_) ""

        H.div ! A.class_ "label" $ H.toHtml ("Groups:" ∷ Text)

        H.div ! A.id "group_input" $
          mconcat
            [ do H.input
                  ! A.id (H.toValue $ "group_" ⊕ show group_number ⊕ "_checkbox")
                  ! A.type_ "checkbox"
                  ! A.name (H.toValue ("group" ∷ Text))
                  ! A.value (H.toValue $ UUID.toText group_id)
                  & checkedIf (member group_id (input_habit ^. input_group_membership_))
                 H.div
                   ! A.class_ "label"
                   ! A.onclick (clickCheckbox $ pack $ "group_" ⊕ show group_number)
                   $ H.toHtml group_name
            | (group_id, group_name) ← groups ^. items_list_
            | group_number ← [0 ∷ Int ..]
            ]

        H.input
          ! A.type_ "hidden"
          ! A.name (H.toValue ("maybe_last_marked" ∷ Text))
          ! inputValue (input_maybe_last_marked_ . format_time_) ""

      H.hr

      H.ul ! A.class_ "error_message" $ foldMap (H.toHtml >>> H.li) error_messages

      H.hr

      case deletion_mode of
        NoDeletion → mempty
        DeletionAvailable → do
          H.input
            ! A.type_ "hidden"
            ! A.name "confirm"
            ! A.value "0"
          H.input
            ! A.type_ "submit"
            ! A.formaction (H.toValue [i|/habits/#{UUID.toText habit_id}/delete|])
            ! A.method "get"
            ! A.value "Delete"
          H.hr
        ConfirmDeletion → do
          H.input
            ! A.type_ "hidden"
            ! A.name "confirm"
            ! A.value "1"
          H.input
            ! A.type_ "submit"
            ! A.formaction (H.toValue [i|/habits/#{UUID.toText habit_id}/delete|])
            ! A.method "get"
            ! A.value "Confirm Delete?"
          H.hr

      H.div ! A.class_ "submit" $ do
        H.a ! A.class_ "sub" ! A.href "/habits" $ toHtml ("Cancel" ∷ Text)
        H.input
          ! A.class_ "sub"
          ! A.formaction (H.toValue [i|/habits/#{UUID.toText habit_id}|])
          ! A.type_ "submit"

handleEditHabitGet ∷ Environment → ScottyM ()
handleEditHabitGet environment = do
  Scotty.get "/habits/:habit_id" <<< webTransaction environment $ do
    habit_id ← getParam "habit_id"
    log [i|Web GET request for habit with id #{habit_id}.|]
    maybe_habit ← use (habits_ . at habit_id)
    renderHabitPage
      habit_id
      mempty
      (case maybe_habit of
        Nothing → NoDeletion
        Just _ → DeletionAvailable
      )
      (maybe def habitToInputHabit maybe_habit)

instance Parsable InputFrequency where
  parseParam "Indefinite" = Right InputIndefinite
  parseParam "Once" = Right InputOnce
  parseParam "Repeated" = Right InputRepeated
  parseParam x = Left $ "Unrecognized frequency type: " ⊕ x

instance Parsable InputRepeated where
  parseParam "Daily" = Right InputDaily
  parseParam "Weekly" = Right InputWeekly
  parseParam x = Left $ "Unrecognized repeated type: " ⊕ x

instance Parsable InputDaysToKeepMode where
  parseParam "KeepDaysInPast" = Right InputKeepDaysInPast
  parseParam "KeepNumberOfDays" = Right InputKeepNumberOfDays
  parseParam x = Left $ "Unrecognized number of days kind: " ⊕ x

getInputHabit ∷ Transaction (InputHabit, Seq Text)
getInputHabit = flip runStateT mempty $ do
  input_frequency ← getInputHabitField "frequency"
  input_once_has_deadline ← lift (getParamMaybe "once_has_deadline") <&> (== Just ("on" ∷ Text))
  input_repeated ← lift (getParamMaybe "repeated")
  InputHabit
    <$> getInputHabitField "name"
    <*> getInputHabitField "difficulty"
    <*> getInputHabitField "importance"
    <*> pure input_frequency
    <*> pure input_once_has_deadline
    <*> (case input_frequency of
          Just InputRepeated → pure input_repeated
          _ → pure Nothing
        )
    <*> (case input_repeated of
          Just InputDaily → getInputHabitField "daily_period"
          _ → pure Nothing
        )
    <*> (case input_repeated of
          Just InputWeekly → getInputHabitField "weekly_period"
          _ → pure Nothing
        )
    <*> (foldlM
          (\previous (_, weekday_name, weekday_lens_) → do
            lift (getParamMaybe weekday_name)
            <&>
            \case
              Just ("on" ∷ Text) → previous & weekday_lens_ #~ True
              _ → previous
          )
          def
          weekdays
        )
    <*> (case input_frequency of
          Just InputRepeated → getInputHabitField "days_to_keep"
          _ → pure Nothing
        )
    <*> (case input_frequency of
          Just InputRepeated → getInputHabitField "days_to_keep_mode"
          _ → pure Nothing
        )
    <*> (do maybe_next_deadline ← lift $ getParamMaybe "next_deadline"
            unless (isJust maybe_next_deadline) $ case input_frequency of
              Just InputRepeated →
                addMessage "next deadline was not given but is required for repeated habits"
              Just InputOnce | input_once_has_deadline →
                addMessage "next deadline was not given but is required for once with deadline"
              _ → pure ()
            pure maybe_next_deadline
        )
    <*> (
          lift getParams
          >>=
          mapM (
            \(key, value) →
              case key of
                "group" →
                  value
                  |> Lazy.toStrict
                  |> UUID.fromText
                  |> maybe
                      (addMessage (pack [i|"Group UUID has invalid format: #{value}|]) >> pure Nothing)
                      (Just >>> pure)
                _ → pure Nothing
          )
          <&>
          (catMaybes >>> setFromList)
        )
    <*> lift (getParamMaybe "maybe_last_marked")
 where
  addMessage = flip snoc >>> modify

  getInputHabitField ∷ Parsable α ⇒ Lazy.Text → StateT (Seq Text) Transaction (Maybe α)
  getInputHabitField name =
    lift (getParamMaybe name)
    >>=
    maybe
      (errorResult [i|#{name} was not given.|])
      (\value → value
         |> Scotty.parseParam
         |> either
              (\_ → errorResult [i|Could not parse #{name} from "#{value}".|])
              (Just >>> pure)
      )
   where
    errorResult message = addMessage (pack message) >> pure Nothing

parseInputHabit ∷ InputHabit → Either Text Habit
parseInputHabit input_habit = Habit
  <$> (tryGetField "name" input_name_ >>= \case
        "" → throwError "name"
        other → pure other
      )
  <*> (Tagged
        <$> (Success <$> tryGetField "difficulty" input_difficulty_)
        <*> (Failure <$> tryGetField "importance" input_importance_)
      )
  <*> (tryGetField "frequency" input_frequency_ >>= \case
        InputIndefinite → pure Indefinite
        InputOnce
          | input_habit ^. input_once_has_deadline_ →
              tryGetField "next deadline" input_next_deadline_ <&> (Just >>> Once)
          | otherwise → pure $ Once Nothing
        InputRepeated →
          Repeated
            <$> (($) <$> (tryGetField "days to keep mode" input_days_to_keep_mode_ <&> \case
                            InputKeepDaysInPast → KeepDaysInPast
                            InputKeepNumberOfDays → KeepNumberOfDays)
                     <*>  tryGetField "days to keep" input_days_to_keep_)
            <*>  tryGetField "next deadline" input_next_deadline_
            <*> (tryGetField "repeated mode" input_repeated_ >>= \case
                  InputDaily →
                    Daily  <$> tryGetField "daily period" input_daily_period_
                  InputWeekly →
                    Weekly <$> tryGetField "weekly period" input_weekly_period_
                           <*> pure (input_habit ^. input_days_to_repeat_)
                )
      )
  <*> (pure $ input_habit ^. input_group_membership_)
  <*> (pure $ input_habit ^. input_maybe_last_marked_)
 where
  tryGetField ∷ Text → Lens' InputHabit (Maybe α) → Either Text α
  tryGetField field_name input_lens_ =
    maybe
      (throwError field_name)
      pure
      (input_habit ^. input_lens_)

handleEditHabitPost ∷ Environment → ScottyM ()
handleEditHabitPost environment = do
  Scotty.post "/habits/:habit_id" <<< webTransaction environment $ do
    habit_id ← getParam "habit_id"
    log [i|Web POST request for habit with id #{habit_id}.|]
    params ← getParams
    (input_habit, input_error_messages) ← getInputHabit
    let displayHabitPage ∷ Seq Text → Transaction TransactionResult
        displayHabitPage error_messages = do
          deletion_mode ←
            use (habits_ . items_map_)
            <&>
            (member habit_id >>> bool NoDeletion DeletionAvailable)
          renderHabitPage habit_id error_messages deletion_mode input_habit
        error_or_habit = parseInputHabit input_habit
    if onull input_error_messages
      then case error_or_habit of
        Right habit_unfiltered → do
          habit ← stripMissingGroupsFromHabit habit_unfiltered
          log [i|Updating habit #{habit_id} to #{habit}|]
          habits_ . at habit_id .= Just habit
          pure $ redirectsToResult temporaryRedirect307 "/habits"
        Left msg → do
          log [i|Failed to update habit #{habit_id} due to parse error: #{msg}|]
          displayHabitPage [msg]
      else do
        log [i|Failed to update habit #{habit_id} due to errors:|]
        let all_error_messages = input_error_messages & case error_or_habit of
              Left msg → (`snoc` msg)
              Right _ → identity
        forM_ all_error_messages $ \msg → log [i|    * #{msg}|]
        displayHabitPage $ all_error_messages

handleDeleteHabitGet ∷ Environment → ScottyM ()
handleDeleteHabitGet environment = do
  Scotty.get "/habits/:habit_id/delete" <<< webTransaction environment $ do
    habit_id ← getParam "habit_id"
    log [i|Web GET request to delete habit with id #{habit_id}.|]
    maybe_habit ← use (habits_ . at habit_id)
    case maybe_habit of
      Nothing → pure $ redirectsToResult temporaryRedirect307 "/habits"
      Just habit → renderHabitPage habit_id mempty DeletionAvailable (habitToInputHabit habit)

handleDeleteHabitPost ∷ Environment → ScottyM ()
handleDeleteHabitPost environment = do
  Scotty.post "/habits/:habit_id/delete" <<< webTransaction environment $ do
    habit_id ← getParam "habit_id"
    log [i|Web POST request to delete habit with id #{habit_id}.|]
    confirm ∷ Int ← getParamMaybe "confirm" <&> fromMaybe 0
    if confirm == 1
      then do
        log [i|Deleting habit #{habit_id}|]
        habits_ . at habit_id .= Nothing
        pure $ redirectsToResult temporaryRedirect307 "/habits"
      else do
        maybe_habit ← use (habits_ . at habit_id)
        case maybe_habit of
          Nothing → do
            log [i|Habit doesn't exist so there is nothing to do.|]
            pure $ redirectsToResult temporaryRedirect307 "/habits"
          Just habit → do
            log [i|Confirming delete for habit #{habit_id}|]
            renderHabitPage habit_id mempty ConfirmDeletion (habitToInputHabit habit)

handler ∷ Environment → ScottyM ()
handler environment = do
  handleEditHabitGet environment
  handleEditHabitPost environment
  handleDeleteHabitGet environment
  handleDeleteHabitPost environment

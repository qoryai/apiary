defmodule Apiary.Repo.Migrations.KeepTheSignUpSettings do
  use Ecto.Migration

  # Who may sign up, as an instance admin saves it in Instance settings › Configuration
  # (`ApiaryPro.SignUp`), used where the variable of the same name in the server's
  # environment is not set, or is empty:
  #
  # `organisations`, whether someone without an invitation may sign up and create an
  # organisation, as SIGNUP_ORGANISATIONS sets it: `open` or `closed`;
  #
  # `operators`, whether they may create an operator, as SIGNUP_OPERATORS sets it: `open`
  # or `closed`.
  #
  # One row at most: its key is a boolean that the check holds to true, as
  # `instance_settings`'s, so a second row has no key left to take. Both NULL until an
  # instance admin saves them, and NULL is the default, `closed`. Who saved them is in the
  # audit trail. No row is the defaults: the table is created empty. It holds nothing of a
  # person or of an organisation, so no purge walks it.
  def change do
    create table(:instance_sign_up, primary_key: false) do
      add :id, :boolean, primary_key: true, default: true
      add :organisations, :text
      add :operators, :text
      add :updated_at, :utc_datetime_usec, null: false
    end

    create constraint(:instance_sign_up, :instance_sign_up_one_row_check, check: "id")

    create constraint(:instance_sign_up, :instance_sign_up_organisations_check,
             check: "organisations IN ('open', 'closed')"
           )

    create constraint(:instance_sign_up, :instance_sign_up_operators_check,
             check: "operators IN ('open', 'closed')"
           )
  end
end

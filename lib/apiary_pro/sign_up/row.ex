defmodule ApiaryPro.SignUp.Row do
  @moduledoc """
  Who may sign up, as an instance admin saves it on Instance settings › Configuration, in
  the one row of `instance_sign_up` (`ApiaryPro.SignUp`): whether a sign-up may create an
  organisation (`organisations`) and an operator (`operators`), each `"open"` or
  `"closed"`, and nil until saved, which is the default, closed. Who saved them is in the
  audit trail.
  """
  use Ecto.Schema

  @primary_key {:id, :boolean, autogenerate: false}
  schema "instance_sign_up" do
    field :organisations, :string
    field :operators, :string
    field :updated_at, :utc_datetime_usec
  end

  @typedoc "The row of who may sign up."
  @type t :: %__MODULE__{}
end

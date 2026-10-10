defmodule Apiary.Mail.Settings do
  @moduledoc """
  The mail settings an instance admin saves in Instance settings › Mail, in the instance's
  own row of `instance_settings` (`Apiary.Mail`): the relay, its port, TLS and username,
  the sender, and the relay's password, kept encrypted (`Apiary.Mail.Password`) and never
  in this struct as plain text but in the changeset of a save, as the virtual field
  `smtp_password`, which `inspect/1` redacts.

  `mail_saved_at` and `mail_saved_by_id` are when and by whom they were saved last, and
  `mail_verified_at` when that admin followed the test link the save sent: mail is on from
  then. A save sets it back to `nil`.

  The schema maps only the mail's columns of the row; the row's other columns are the
  instance's other settings (`Apiary.KeyCheck`).
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @tls ~w(always if_available never)

  @primary_key {:id, :boolean, autogenerate: false}
  schema "instance_settings" do
    field :smtp_relay, :string
    field :smtp_port, :integer
    field :smtp_tls, :string
    field :smtp_username, :string
    field :mail_from, :string
    field :smtp_password, :string, virtual: true, redact: true
    field :smtp_password_ciphertext, :binary, redact: true
    field :mail_key_id, :string
    field :mail_saved_at, :utc_datetime_usec
    field :mail_saved_by_id, :binary_id
    field :mail_verified_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @typedoc "The mail settings of the instance's row."
  @type t :: %__MODULE__{}

  @doc "The values `smtp_tls` takes, as `SMTP_TLS` does."
  @spec tls_values() :: [String.t()]
  def tls_values, do: @tls

  @doc """
  changeset/2 is what an instance admin saves: the relay, required, a host name of at most
  253 characters without a scheme, a port or a space; the port, 1 to 65535, 587 when
  empty; TLS, one of `tls_values/0`, `always` when empty; the username, empty for a relay
  without a log-in; the sender, an email address or empty for the server's default; and
  the password, the virtual `smtp_password`, empty for none given. Each value is trimmed
  but the password, and an empty one is `nil`.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:smtp_relay, :smtp_port, :smtp_tls, :smtp_username, :mail_from])
    |> cast(attrs, [:smtp_password], empty_values: [nil, ""])
    |> update_change(:smtp_relay, &blank_to_nil/1)
    |> update_change(:smtp_username, &blank_to_nil/1)
    |> update_change(:mail_from, &blank_to_nil/1)
    |> default(:smtp_port, 587)
    |> default(:smtp_tls, "always")
    |> validate_required([:smtp_relay])
    |> validate_length(:smtp_relay, max: 253)
    |> validate_format(:smtp_relay, ~r/\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z/,
      message: dgettext_noop("errors", "must be a host name, such as smtp.example.com")
    )
    |> validate_number(:smtp_port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> validate_inclusion(:smtp_tls, @tls)
    |> validate_length(:smtp_username, max: 320)
    |> validate_length(:smtp_password, max: 1_000)
    |> validate_length(:mail_from, max: 160)
    |> validate_format(:mail_from, ~r/\A[^@,;<>"\s]+@[^@,;<>"\s]+\z/,
      message: dgettext_noop("errors", "must have the @ sign and no spaces")
    )
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # A field left empty takes its default, as the variable of the same name unset does.
  defp default(changeset, field, value) do
    if get_field(changeset, field) in [nil, ""],
      do: put_change(changeset, field, value),
      else: changeset
  end

  @doc """
  without_password/1 is `changeset` with the password it was given taken out of its changes
  and its parameters, so a form made from it, which a page keeps, never holds it. A
  password given stays in the parameters as an empty one, so the form still shows the
  field's errors.
  """
  @spec without_password(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def without_password(%Ecto.Changeset{} = changeset) do
    changeset = delete_change(changeset, :smtp_password)

    case changeset.params do
      %{"smtp_password" => _given} = params ->
        %{changeset | params: Map.put(params, "smtp_password", "")}

      _none ->
        changeset
    end
  end
end

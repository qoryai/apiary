defmodule Apiary.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias Apiary.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  @change_email_validity_in_days 7
  @session_validity_in_days 14

  # A password link (`Apiary.Accounts.build_password_link/3`) sets the account's password,
  # so whoever holds it may take the account over: it works once, and for a day when an
  # instance admin makes it, an hour when a release command prints it on a terminal.
  @password_link_validity_in_minutes %{"password" => 24 * 60, "password:release" => 60}
  @password_link_contexts Map.keys(@password_link_validity_in_minutes)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    belongs_to :user, Apiary.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix's default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired. The token system can also be extended
  to store additional data, such as the device used for logging in.
  You could then use this information to display all valid sessions
  and devices in the UI and allow users to explicitly expire any
  session they deem invalid.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || DateTime.utc_now(:second)
    {token, %UserToken{token: token, context: "session", user_id: user.id, authenticated_at: dt}}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token's creation time.

  The token is valid if it matches the value in the database and it has
  not expired (after @session_validity_in_days), and its account is in use: not deleted,
  and active as the edition says (`c:Apiary.Edition.active_accounts/2`).
  """
  def verify_session_token_query(token) do
    query =
      from(token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        as: :account,
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        where: is_nil(user.deleted_at),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}
      )
      |> Apiary.Edition.active_accounts(:account)

    {:ok, query}
  end

  @doc """
  Builds a token and its hash to be delivered to the user's email.

  The non-hashed token is sent to the user email while the
  hashed part is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access. Furthermore, if the user changes
  their email in the system, the tokens sent to the previous email are no longer
  valid.

  Users can easily adapt the existing code to provide other types of delivery methods,
  for example, by phone numbers.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  @doc """
  Builds a password link's token and its hash, as `build_email_token/2` builds a log-in
  link's: the encoded token goes into the link, and only its hash is stored, with the
  account's address, so a change of address ends the link. `context` is `"password"`, the
  link an instance admin makes, which works for a day, or until mail is set
  (`Apiary.Mail.end_password_links/0`), or `"password:release"`, the one a
  release command prints, which works for an hour (`password_link_validity_in_minutes/1`).
  """
  def build_password_link_token(user, context) when context in @password_link_contexts do
    build_hashed_token(user, context, user.email)
  end

  @doc "The contexts of a password link's token: one for each way to make one."
  def password_link_contexts, do: @password_link_contexts

  @doc "How long a password link of `context` works, in minutes."
  def password_link_validity_in_minutes(context),
    do: Map.fetch!(@password_link_validity_in_minutes, context)

  @doc """
  Checks a password link's token and returns its lookup query, `{:ok, query}`, or
  `:error` for a token that is not one.

  The query returns `{user, token}` when the token matches the hash of a password link,
  of either context, younger than that context's validity, sent to the address the account
  has now, of an account that is not deleted.
  """
  def verify_password_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)
        day = @password_link_validity_in_minutes["password"]
        hour = @password_link_validity_in_minutes["password:release"]

        query =
          from token in UserToken,
            join: user in assoc(token, :user),
            where: token.token == ^hashed_token,
            where:
              (token.context == "password" and token.inserted_at > ago(^day, "minute")) or
                (token.context == "password:release" and
                   token.inserted_at > ago(^hour, "minute")),
            where: token.sent_to == user.email and is_nil(user.deleted_at),
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  If found, the query returns a tuple of the form `{user, token}`.

  The given token is valid if it matches its hashed counterpart in the
  database. This function also checks whether the token has expired. The context
  of a magic link token is always "login".
  """
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "login"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@magic_link_validity_in_minutes, "minute"),
            where: token.sent_to == user.email and is_nil(user.deleted_at),
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user_token found by the token, if any.

  This is used to validate requests to change the user
  email.
  The given token is valid if it matches its hashed counterpart in the
  database and if it has not expired (after @change_email_validity_in_days).
  The context must always start with "change:".
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end

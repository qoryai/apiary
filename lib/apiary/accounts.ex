defmodule Apiary.Accounts do
  @moduledoc """
  The accounts: a person's account, its sign-in and its tokens.

  An account belongs to no organisation. It holds the person's personal data, the email
  address, the password and the preferences, and nothing else does: every other row names
  the person by the account's id. So an account is never deleted: `delete_user/2` makes
  it a tombstone, which keeps its id and erases the rest, and a page that names the person
  says "Former member". Signing in, a log-in link and a session never find a tombstone,
  and its address is free for a new sign-up at once, which makes a new account.
  """

  import Ecto.Query, warn: false
  alias Apiary.{Organisations, Repo}

  alias Apiary.Accounts.{Scope, User, UserToken, UserNotifier}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.one(from u in User, where: u.email == ^email and is_nil(u.deleted_at))
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Apiary.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Apiary.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user's preferences: language, time zone
  and skin (`Apiary.Accounts.Preferences`).
  """
  @spec change_user_preferences(%User{}, map) :: Ecto.Changeset.t()
  def change_user_preferences(%User{} = user, attrs \\ %{}) do
    User.preferences_changeset(user, attrs)
  end

  @doc """
  Updates the user's preferences. They are the person's own, in every organisation, so
  the user is the only argument beside them; the session tokens are kept.

  Returns `{:ok, user}`, or `{:error, changeset}` for a language the application has no
  catalogue for, a time zone the zone database does not know or a skin that does not
  exist.
  """
  @spec update_user_preferences(%User{}, map) :: {:ok, %User{}} | {:error, Ecto.Changeset.t()}
  def update_user_preferences(%User{} = user, attrs) do
    user
    |> User.preferences_changeset(attrs)
    |> Repo.update()
  end

  ## Deletion

  @doc """
  delete_user/2 deletes an account. It becomes a tombstone (`User.delete_changeset/1`):
  its id stays, with the time it was deleted, and its email address, password and
  preferences are erased. Its memberships are deleted, each an entry in its
  organisation's trail (`Apiary.Organisations.end_memberships/2`), and so are its session
  and email tokens. What the person made in a workspace, an access key, a rule, a run's
  closing, stays with the workspace and names the tombstone. All of it in one
  transaction.

  Given the person's scope, the person deletes their own account: the page asks for a
  recent sign-in first (`sudo_mode?/2`), and the entries are the person's. Given a user
  and an `origin:`, the instance deletes it, as a release command
  does (`Apiary.Release.delete_account/1`), and the entries are the instance's. Nobody is
  asked of `Apiary.Access`: an account is no organisation's.

  `{:ok, {tombstone, tokens}}`, with the tokens deleted, whose open sessions the caller
  disconnects. `{:error, :last_owner}` while the person is the only owner of an
  organisation in use (`Apiary.Organisations.sole_owned_organisations/2`), who has to
  make another member an owner or delete the organisation first; `{:error, :not_found}`
  for an account already deleted.
  """
  @spec delete_user(Scope.t() | %User{}, keyword) ::
          {:ok, {%User{}, [%UserToken{}]}} | {:error, :last_owner | :not_found | term}
  def delete_user(scope_or_user, opts \\ [])

  def delete_user(%Scope{user: %User{} = user, origin: origin}, _opts) do
    delete(user, fn organisation ->
      %Scope{user: user, organisation: organisation, origin: origin}
    end)
  end

  def delete_user(%User{} = user, opts) do
    origin = Keyword.get(opts, :origin)
    delete(user, &(&1 |> Scope.for_instance() |> Scope.put_origin(origin)))
  end

  defp delete(%User{id: id}, actor) do
    Repo.transact(fn ->
      # The lock order (docs/access.md): the organisations the person owns and their
      # owners (`Organisations.sole_owned_organisations/2` with `lock: true`), then the
      # person's memberships, then the account, `FOR NO KEY UPDATE`: an invitation's
      # acceptance, which holds the account `FOR SHARE`, waits for it, and one that came
      # first is waited for; a row that only names the account, which takes its key share,
      # does not, so the person's own changes in another tab do not deadlock with it.
      sole_owned = Organisations.sole_owned_organisations(%User{id: id}, lock: true)
      :ok = Organisations.lock_memberships(%User{id: id})

      with %User{} = user <-
             Repo.one(
               from u in User,
                 where: u.id == ^id and is_nil(u.deleted_at),
                 lock: "FOR NO KEY UPDATE"
             ) ||
               {:error, :not_found},
           [] <- sole_owned,
           {:ok, memberships} <- Organisations.end_memberships(user, actor),
           tokens = Repo.all_by(UserToken, user_id: id),
           {_count, _} = Repo.delete_all(from t in UserToken, where: t.user_id == ^id),
           {:ok, tombstone} <- user |> User.delete_changeset() |> Repo.update() do
        {:ok, {tombstone, tokens, memberships}}
      else
        [_ | _] -> {:error, :last_owner}
        {:error, _reason} = error -> error
      end
    end)
    |> case do
      {:ok, {tombstone, tokens, memberships}} ->
        Organisations.broadcast_membership_changes(memberships)
        {:ok, {tombstone, tokens}}

      {:error, _reason} = error ->
        error
    end
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  sign_in_refusal/1 is why the account may not sign in though its password or log-in
  link was right, as the edition says (`c:Apiary.Edition.account_refusal/1`), or nil; nil
  for no account.
  """
  @spec sign_in_refusal(%User{} | nil) :: atom | nil
  def sign_in_refusal(%User{} = user), do: Apiary.Edition.account_refusal(user)
  def sign_in_refusal(nil), do: nil

  @doc """
  Logs the user in by magic link: `{:error, reason}` for an account the edition refuses
  (`sign_in_refusal/1`), whose link is used up and which is not logged in.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  @spec login_user_by_magic_link(String.t()) ::
          {:ok, {%User{}, [%UserToken{}]}} | {:error, atom | Ecto.Changeset.t()}
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {user, token} ->
        case sign_in_refusal(user) do
          # An account the edition refuses signs in nowhere; the link is used up.
          reason when is_atom(reason) and not is_nil(reason) ->
            Repo.delete!(token)
            {:error, reason}

          nil ->
            log_in(user, token)
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp log_in(%User{confirmed_at: nil} = user, _token) do
    user
    |> User.confirm_changeset()
    |> update_user_and_delete_all_tokens()
  end

  defp log_in(user, token) do
    Repo.delete!(token)
    {:ok, {user, []}}
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end

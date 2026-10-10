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
    # Text Postgres refuses, a NUL or bytes that are not UTF-8, is no account's address.
    if String.valid?(email) and not String.contains?(email, <<0>>) do
      Repo.one(from u in User, where: u.email == ^email and is_nil(u.deleted_at))
    end
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

  The account's row is held while the password is set, as a log-in link's confirmation
  holds it (`login_user_by_magic_link/1`), so the two take turns. `{:error, :stale}` when
  `user` is not the account as it is now: its confirmation differs, as after a first
  log-in link that removed a password set before it (case 3 there), or it is deleted; and,
  with `session_token:`, the caller's session token, when that session no longer exists.
  Nothing is set then.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_user_password(%User{}, map, keyword) ::
          {:ok, {%User{}, [%UserToken{}]}} | {:error, Ecto.Changeset.t() | :stale}
  def update_user_password(%User{} = user, attrs, opts \\ []) do
    # Hashed before the transaction, which holds the account's row meanwhile.
    case User.password_changeset(user, attrs) do
      %Ecto.Changeset{valid?: false} = changeset ->
        {:error, %{changeset | action: :update}}

      changeset ->
        Repo.transact(fn ->
          with {:ok, locked} <- lock_account(user.id),
               true <- locked.confirmed_at == user.confirmed_at,
               true <- session_alive?(user, Keyword.get(opts, :session_token)) do
            update_user_and_delete_all_tokens(%{changeset | data: locked})
          else
            _stale -> {:error, :stale}
          end
        end)
    end
  end

  defp session_alive?(_user, nil), do: true

  defp session_alive?(%User{id: id}, token) when is_binary(token) do
    Repo.exists?(
      from t in UserToken,
        where: t.token == ^token and t.context == "session" and t.user_id == ^id
    )
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
  and email tokens. What the person made in a workspace, an access key or a rule, stays with
  the workspace and names the tombstone. All of it in one
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

  1. The account's address is confirmed. It is logged in and the link is used up:
     `{:ok, {user, []}}`.

  2. The address is not confirmed and no password is set. The link confirms it, logs the
     account in and ends every token of the account, its sessions included:
     `{:ok, {user, tokens}}`, with the tokens deleted, whose sessions the caller
     disconnects.

  3. The address is not confirmed and a password is set: one chosen at a sign-up without
     mail, or in Account settings, before anyone showed the address was theirs. Whoever
     set it may not be the address's owner, who now follows a link sent to it. The link
     confirms the address, **removes the password** and ends every token of the account,
     its sessions included, so whoever set it keeps no way in:
     `{:ok, {user, tokens}, :password_removed}`, and the page says so. This is
     phx.gen.auth's guard for mixing log-in links and passwords ("Mixing magic link and
     password registration" in `mix help phx.gen.auth`).
  """
  @spec login_user_by_magic_link(String.t()) ::
          {:ok, {%User{}, [%UserToken{}]}}
          | {:ok, {%User{}, [%UserToken{}]}, :password_removed}
          | {:error, atom | Ecto.Changeset.t()}
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
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

  # An unconfirmed account: confirmed, its password removed if it has one (case 3 above),
  # every token ended (cases 2 and 3). The account is read again under its lock, so a
  # password set meanwhile goes too, and the answer says what was done.
  defp log_in(%User{confirmed_at: nil, id: id}, token) do
    Repo.transact(fn ->
      locked =
        Repo.one(
          from u in User,
            where: u.id == ^id and is_nil(u.deleted_at),
            lock: "FOR NO KEY UPDATE"
        )

      confirm(locked, token)
    end)
    |> case do
      {:ok, {:password_removed, result}} -> {:ok, result, :password_removed}
      {:ok, {_kept, result}} -> {:ok, result}
      {:error, _reason} = error -> error
    end
  end

  defp log_in(user, token) do
    Repo.delete!(token)
    {:ok, {user, []}}
  end

  defp confirm(nil, _token), do: {:error, :not_found}

  # Confirmed by another link meanwhile: logged in as a confirmed account is, while this
  # link is still there to use up. The confirmation ended every token, this link's too
  # when it was the one that confirmed, so a second use of it finds it gone.
  defp confirm(%User{confirmed_at: %DateTime{}} = user, token) do
    case Repo.delete_all(from t in UserToken, where: t.id == ^token.id) do
      {1, _} -> {:ok, {:kept, {user, []}}}
      {0, _} -> {:error, :not_found}
    end
  end

  defp confirm(%User{hashed_password: hash} = user, _token) do
    changeset =
      user
      |> User.confirm_changeset()
      |> Ecto.Changeset.put_change(:hashed_password, nil)

    with {:ok, result} <- update_user_and_delete_all_tokens(changeset) do
      {:ok, {if(is_binary(hash), do: :password_removed, else: :kept), result}}
    end
  end

  ## Password links

  @doc """
  build_password_link/3 makes a one-time link that sets the password of `user`'s account,
  for a person who forgot theirs while the instance sends no mail, or for a release
  command: `url_fun` turns the token into the link (`/users/password/:token`,
  `set_password_by_link/2`). `{:ok, url, expires_at}`.

  **Who makes one.** `by` is the scope of whoever asks:

  - an instance admin (`Apiary.Access.instance_admin?/1`), while no mail is set
    (`Apiary.Mail.configured?/0`): a link that works for 24 hours, context `"password"`.
    `{:error, :forbidden}` for anyone else, and `{:error, :mail_set}` once mail is set,
    when the person asks for a log-in link instead. Never for their own account,
    `{:error, :own_account}`: they change their own password in Account settings, behind
    a recent sign-in, which a link would get around;
  - the instance (`Apiary.Accounts.Scope.for_instance/2`), a release command run on the
    instance's machine, which controls it already, mail or not: a link that works for an
    hour, context `"password:release"`.

  **The token** is 32 random bytes; only its SHA-256 hash is stored, in `users_tokens`,
  with the account's address (`Apiary.Accounts.UserToken`). It works once. The account
  has one password link at a time: a new one ends the one before. Nothing else changes
  until the link is used: the password the account has, if any, and its sessions stay.

  **The trail.** Each link is an `account.password_link` entry in the instance's
  organisation's trail (`c:Apiary.Edition.instance_organisation_id/0`), by the person or
  the instance, from the scope's origin: about the account's membership there when it has
  one, else about the organisation, naming the account by user id in `details`, never the
  link. `{:error, :no_instance_organisation}` before the instance's first sign-up.

  `{:error, :not_found}` for an account deleted, and the edition's refusal for one it
  refuses (`sign_in_refusal/1`), which gets no link.
  """
  @spec build_password_link(Scope.t(), %User{}, (String.t() -> String.t())) ::
          {:ok, String.t(), DateTime.t()}
          | {:error,
             :forbidden | :mail_set | :own_account | :not_found | :no_instance_organisation | atom}
  def build_password_link(%Scope{} = by, %User{id: user_id}, url_fun)
      when is_function(url_fun, 1) do
    context = if by.instance and is_nil(by.user), do: "password:release", else: "password"

    Repo.transact(fn ->
      with :ok <- may_make_password_link(by),
           :ok <- not_own_account(by, user_id),
           {:ok, organisation} <- instance_organisation(),
           {:ok, user} <- lock_account(user_id),
           :ok <- not_refused(user) do
        Repo.delete_all(
          from t in UserToken,
            where: t.user_id == ^user.id and t.context in ^UserToken.password_link_contexts()
        )

        {encoded_token, user_token} = UserToken.build_password_link_token(user, context)
        user_token = Repo.insert!(user_token)

        expires_at =
          DateTime.add(
            user_token.inserted_at,
            UserToken.password_link_validity_in_minutes(context) * 60
          )

        with {:ok, _entry} <-
               Apiary.Audit.record(
                 Repo,
                 audit_scope(by, organisation),
                 :"account.password_link",
                 password_link_subject(organisation, user),
                 %{details: %{user_id: user.id, expires_at: expires_at}}
               ),
             do: {:ok, {url_fun.(encoded_token), expires_at}}
      end
    end)
    |> case do
      {:ok, {url, expires_at}} -> {:ok, url, expires_at}
      {:error, _reason} = error -> error
    end
  end

  # The instance, in a release command, may make one, mail or not; a person only as an
  # instance admin, and only while no mail is set.
  defp may_make_password_link(%Scope{instance: true, user: nil, access_key: nil}), do: :ok

  defp may_make_password_link(%Scope{user: %User{}} = scope) do
    cond do
      not Apiary.Access.instance_admin?(scope) -> {:error, :forbidden}
      Apiary.Mail.configured?() -> {:error, :mail_set}
      true -> :ok
    end
  end

  defp may_make_password_link(_scope), do: {:error, :forbidden}

  # A person's own password is changed in Account settings, behind a recent sign-in.
  defp not_own_account(%Scope{user: %User{id: id}}, id), do: {:error, :own_account}
  defp not_own_account(_by, _user_id), do: :ok

  defp instance_organisation do
    with id when is_binary(id) <- Apiary.Edition.instance_organisation_id(),
         %Apiary.Organisations.Organisation{} = organisation <-
           Repo.get(Apiary.Organisations.Organisation, id) do
      {:ok, organisation}
    else
      _none -> {:error, :no_instance_organisation}
    end
  end

  # The account, while it is not deleted, held for the transaction: its deletion waits, or
  # is seen.
  defp lock_account(user_id) do
    case Repo.one(
           from u in User,
             where: u.id == ^user_id and is_nil(u.deleted_at),
             lock: "FOR NO KEY UPDATE"
         ) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  end

  defp not_refused(user) do
    case sign_in_refusal(user) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  defp audit_scope(%Scope{instance: true, user: nil} = by, organisation),
    do: organisation |> Scope.for_instance() |> Scope.put_origin(by.origin)

  defp audit_scope(by, organisation), do: Scope.in_organisation(by, organisation)

  defp password_link_subject(organisation, user) do
    Repo.get_by(Apiary.Organisations.Membership,
      organisation_id: organisation.id,
      user_id: user.id
    ) || organisation
  end

  @doc """
  get_user_by_password_link/1 is the account a password link sets the password of, while
  the link works (`build_password_link/3`); nil for a token that is none, used, ended by a
  newer one or expired, and for an account deleted or whose address changed since.
  """
  @spec get_user_by_password_link(String.t()) :: %User{} | nil
  def get_user_by_password_link(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_password_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  set_password_by_link/2 sets the password of the account a password link is for
  (`build_password_link/3`), from `attrs`' `password` and `password_confirmation`, checked
  as `User.password_changeset/3` checks them, and uses the link up. As a change of
  password in Account settings does, it ends every token of the account, its sessions
  included, which the caller disconnects: `{:ok, {user, tokens}}`.

  A password that is refused is `{:error, changeset}`, and the link still works. A link
  that does not work is `{:error, :invalid}`; of two uses at once, one sets the password
  and the other gets that. Nothing is done for an account the edition refuses
  (`sign_in_refusal/1`), `{:error, reason}`.
  """
  @spec set_password_by_link(String.t(), map) ::
          {:ok, {%User{}, [%UserToken{}]}} | {:error, :invalid | atom | Ecto.Changeset.t()}
  def set_password_by_link(token, attrs) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_password_link_token_query(token),
         {user, user_token} <- Repo.one(query),
         :ok <- not_refused(user) do
      # Hashed before the transaction, which holds the account's row meanwhile.
      user
      |> User.password_changeset(attrs)
      |> set_password(user_token)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :invalid}
    end
  end

  defp set_password(%Ecto.Changeset{valid?: false} = changeset, _user_token),
    do: {:error, %{changeset | action: :update}}

  defp set_password(changeset, user_token) do
    Repo.transact(fn ->
      # The link is used up first: a use at the same moment waits, then finds it gone.
      with {1, _} <- Repo.delete_all(from t in UserToken, where: t.id == ^user_token.id),
           {:ok, user} <- lock_account(user_token.user_id),
           true <- user.email == user_token.sent_to do
        update_user_and_delete_all_tokens(%{changeset | data: user})
      else
        _gone -> {:error, :invalid}
      end
    end)
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

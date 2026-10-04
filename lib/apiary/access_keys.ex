defmodule Apiary.AccessKeys do
  @moduledoc """
  Access keys: a workspace's credentials for the server contract, of two kinds
  (`Apiary.AccessKeys.AccessKey`).

  **Today's keys** have a key id and one or two secrets the server made, encrypted at
  rest, and no node; the workspace's settings list them (`list_access_keys/1`). The
  secret is returned exactly once, from `create_access_key/2` and `rotate_access_key/2`,
  and is never read back through this module except for verification. Every member makes,
  rotates and revokes them (`access_key.create`, `access_key.rotate`,
  `access_key.revoke_secret_key`).

  **A node's keys** each have one Ed25519 public key and belong to one node or node pool
  of the workspace (`Apiary.Nodes`); a node holds several over its life. Owners and admins
  alone manage them:

    * an **enrolment code** (`create_enrolment_code/3`, `access_key.create_code`) is
      single use and expires after `code_ttl_minutes/0`; it carries the settings the key
      it brings gets, and is returned once, kept only as its SHA-256; an outstanding one
      is cancelled with `cancel_code/2` (`access_key.cancel_code`);
    * a **pasted key** (`add_access_key/3`, `access_key.add`) is approved as it is
      entered;
    * a key that **awaits approval** is approved (`approve/2`, `access_key.approve`) or
      rejected (`reject/2`, `access_key.reject`); an approved one is revoked
      (`revoke_access_key/2`, `access_key.revoke`), and every key of a deleted node with
      it (`Apiary.Nodes.delete_node/2`).

  A node holds at most two approved keys and one that awaits approval: a paste is refused
  while it holds two keys, approved or not, and an approval while it holds two approved
  ones, `{:error, :key_limit}`. A key's label is unique among the node's keys in use. Its
  stored-secrets flag is fixed when it is made; there is no rotation of a node's key: to
  change the flag, or replace a lost key, a new key is added for the same node, and the
  old one revoked.

  **The checks.** Every public key received passes the key checks of
  `Apiary.Contract.Ed25519` and is not in the ledger (`Apiary.AccessKeys.PublicKey`),
  where every node's key's public key is written in the transaction that makes the key
  and stays, a tombstone once the key is retired: one public key, one access key, ever. A
  key refused by either gets one answer, "this key cannot be used", so a refusal reveals
  nothing about other keys. A node's key's row and an enrolment code's carry an integrity
  code (`Apiary.Integrity`), written with every change and checked before the row is
  trusted: `fetch_for_verification/1` refuses a key whose row does not match it, and an
  approval refuses one too.

  **Locks.** A change of a node's keys locks the node's row `FOR UPDATE`, then the key's
  or the code's, so the limits count every change before them.

  Every change of a key leaves an audit entry (`Apiary.Audit`) in its transaction: its
  label and key id when it is created, the rotation or the retirement of the previous
  secret as `access_key.rotate`, the revocation; a node's key's arrival, approval,
  rejection and revocation, with its fingerprint; a code's making and cancelling, on its
  node. Never a secret, nor a code.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Audit, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Contract.Ed25519
  alias Apiary.LogMetadata
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Workspace, Organisation}

  @default_code_ttl_minutes 15
  @max_code_ttl_minutes 15
  @approved_limit 2
  @pending_limit 1

  defguardp key_in_scope(scope, access_key)
            when access_key.organisation_id == scope.organisation.id and
                   access_key.workspace_id == scope.workspace.id

  @doc """
  The workspace's keys of today, those with a secret and no node: active first, then
  revoked; newest first within each. The secret columns are not loaded; `rotating` says
  whether a previous secret exists. A node's keys are `list_for_node/2`'s.
  """
  def list_access_keys(%Scope{
        organisation: %Organisation{id: organisation_id},
        workspace: %Workspace{id: workspace_id}
      }) do
    Repo.all(
      from k in without_secrets_query(),
        where: k.organisation_id == ^organisation_id and k.workspace_id == ^workspace_id,
        where: is_nil(k.node_id),
        order_by: [asc: not is_nil(k.revoked_at), desc: k.inserted_at, desc: k.id]
    )
  end

  @doc """
  One key of today of the scope's workspace, without its secrets (see
  `list_access_keys/1`).
  """
  def get_access_key!(
        %Scope{
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id}
        },
        id
      ) do
    Repo.one!(
      from k in without_secrets_query(),
        where:
          k.id == ^id and k.organisation_id == ^organisation_id and
            k.workspace_id == ^workspace_id and is_nil(k.node_id)
    )
  end

  # Decrypted secrets have no business in a LiveView's state: the web layer gets
  # rows selected without the secret columns.
  defp without_secrets_query do
    from k in AccessKey,
      select: struct(k, ^AccessKey.public_fields()),
      select_merge: %{rotating: not is_nil(k.secret_secondary)}
  end

  def change_access_key(%AccessKey{} = access_key, attrs \\ %{}) do
    AccessKey.changeset(access_key, attrs)
  end

  @doc """
  Creates a key for the scope's workspace (`access_key.create`, which every member may): a
  caller whose membership is gone gets `{:error, :forbidden}`. Returns the key (without
  secrets) and its secret, the only time the secret is available in clear.
  """
  def create_access_key(
        %Scope{
          user: user,
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id} = workspace
        } = scope,
        attrs
      ) do
    with :ok <- Access.authorize(scope, :"access_key.create", workspace) do
      secret = AccessKey.generate_secret()

      changeset =
        %AccessKey{
          organisation_id: organisation_id,
          workspace_id: workspace_id,
          created_by_id: user.id,
          key_id: AccessKey.generate_key_id(),
          # A closure, so the query log sees a function and never the secret
          # (Ecto logs the cast parameters; Cloak unwraps the closure on dump).
          secret_primary: fn -> secret end
        }
        |> AccessKey.changeset(attrs)

      Repo.transact(fn ->
        with {:ok, access_key} <- Repo.insert(changeset),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"access_key.create", access_key, %{
                 after: %{label: access_key.label, key_id: access_key.key_id}
               }) do
          {:ok, access_key}
        end
      end)
      |> case do
        {:ok, access_key} ->
          {:ok, AccessKey.without_secrets(%{access_key | secret_primary: nil}), secret}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Rotates the key (`access_key.rotate`): a new primary secret, the old primary kept as
  the secondary so a node still on it keeps verifying; a previous secondary is dropped.

  The row is read again and locked, so the secret kept as the secondary is the
  one in the database now, whatever the struct passed in remembers.
  """
  def rotate_access_key(%Scope{} = scope, %AccessKey{} = access_key)
      when key_in_scope(scope, access_key) do
    mutate(scope, :"access_key.rotate", access_key, fn
      %AccessKey{revoked_at: revoked_at} when not is_nil(revoked_at) ->
        {:error, :revoked}

      %AccessKey{secret_primary: previous} = current ->
        secret = AccessKey.generate_secret()

        with {:ok, updated} <-
               current
               |> Ecto.Changeset.change(
                 secret_primary: fn -> secret end,
                 secret_secondary: previous && fn -> previous end,
                 rotated_at: DateTime.utc_now()
               )
               |> Repo.update(),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"access_key.rotate", updated, %{
                 before: %{rotated_at: current.rotated_at},
                 after: %{rotated_at: updated.rotated_at},
                 details: %{change: "rotated"}
               }) do
          {:ok, {updated, secret}}
        end
    end)
  end

  @doc "Drops the secondary secret: the rotation is complete (`access_key.rotate`)."
  def retire_previous_secret(%Scope{} = scope, %AccessKey{} = access_key)
      when key_in_scope(scope, access_key) do
    mutate(scope, :"access_key.rotate", access_key, fn
      %AccessKey{secret_secondary: nil} = current ->
        {:ok, current}

      current ->
        with {:ok, updated} <-
               current |> Ecto.Changeset.change(secret_secondary: nil) |> Repo.update(),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"access_key.rotate", updated, %{
                 before: %{previous_secret: true},
                 after: %{previous_secret: false},
                 details: %{change: "previous_retired"}
               }) do
          {:ok, updated}
        end
    end)
  end

  @doc """
  Revokes the key: verification fails from now on. Today's key is revoked by any member
  (`access_key.revoke_secret_key`); a node's key by an owner or an admin
  (`access_key.revoke`), once approved: its public key becomes a tombstone in the ledger,
  and a key that awaits approval is rejected instead (`reject/2`), `{:error, :pending}`.
  Revoking a revoked key changes nothing.
  """
  @spec revoke_access_key(Scope.t(), AccessKey.t()) ::
          {:ok, AccessKey.t()} | {:error, :pending | Access.reason()}
  def revoke_access_key(%Scope{} = scope, %AccessKey{node_id: node_id} = access_key)
      when key_in_scope(scope, access_key) and is_binary(node_id) do
    change_node_key(scope, :"access_key.revoke", access_key, fn node, current ->
      case AccessKey.status(current) do
        :revoked ->
          {:ok, current}

        :pending ->
          {:error, :pending}

        _active ->
          retire(scope, node, current, :"access_key.revoke", :revoked)
      end
    end)
  end

  def revoke_access_key(%Scope{} = scope, %AccessKey{} = access_key)
      when key_in_scope(scope, access_key) do
    mutate(scope, :"access_key.revoke_secret_key", access_key, fn
      %AccessKey{revoked_at: %DateTime{}} = current ->
        {:ok, current}

      current ->
        with {:ok, updated} <-
               current |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update(),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"access_key.revoke_secret_key", updated, %{
                 before: %{revoked_at: nil},
                 after: %{revoked_at: updated.revoked_at}
               }) do
          {:ok, updated}
        end
    end)
  end

  # Authorizes `action` on the caller's membership as it is now, then hands `fun` the
  # key as it is now, locked for the rest of the transaction. The result leaves
  # without secrets.
  defp mutate(%Scope{} = scope, action, %AccessKey{id: id} = access_key, fun) do
    fn ->
      with :ok <- Access.authorize(scope, action, access_key),
           {:ok, current} <- lock_access_key(scope, id) do
        fun.(current)
      end
    end
    |> Repo.transact()
    |> case do
      {:ok, %AccessKey{} = access_key} ->
        {:ok, AccessKey.without_secrets(access_key)}

      {:ok, {%AccessKey{} = access_key, secret}} ->
        {:ok, AccessKey.without_secrets(access_key), secret}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Today's keys only: a node's key has no secret to rotate, and is revoked under its
  # node's lock (`change_node_key/4`).
  defp lock_access_key(%Scope{organisation: organisation, workspace: workspace}, id) do
    query =
      from k in AccessKey,
        where:
          k.id == ^id and k.organisation_id == ^organisation.id and
            k.workspace_id == ^workspace.id and is_nil(k.node_id),
        lock: "FOR UPDATE"

    # A secret that cannot be decrypted with the key the instance holds (see
    # `readable?/1`) is dropped here, never carried over: a rotation issues a new secret
    # in its place, and a revocation still revokes.
    case Repo.one(query) do
      %AccessKey{} = access_key -> {:ok, drop_unreadable(access_key)}
      nil -> {:error, :not_found}
    end
  end

  defp drop_unreadable(%AccessKey{} = access_key) do
    %{
      access_key
      | secret_primary: if(is_binary(access_key.secret_primary), do: access_key.secret_primary),
        secret_secondary:
          if(is_binary(access_key.secret_secondary), do: access_key.secret_secondary)
    }
  end

  @doc """
  The key behind a key id, secrets decrypted, for request verification: `:error`
  for a key id the workspace does not hold or has revoked, for a key of a workspace or
  an organisation marked for deletion (`Apiary.Deletion`), which answers as a revoked key
  does until its deletion is cancelled, and for a key of an organisation the edition
  stopped (`c:Apiary.Edition.active_organisations/2`), which answers so until it is in use
  again: a key is a workspace's, not a person's, so a suspended membership or an account
  out of use leaves the keys working; `{:error, :unreadable}`,
  with a line in the log, when the secrets cannot be decrypted with the key the instance
  holds (`APIARY_ENCRYPTION_SECRET` is not the one they were encrypted with). The key comes
  with its workspace, read in the same query: its domain names a run's target
  (`Apiary.Policy.Serving`).

  A node's key comes with its node too, whether it is approved or awaits approval
  (`AccessKey.status/1`), which the caller asks; it has no secret, so no secret verifies
  a request under it. Its integrity code is checked first: a row that does not match it,
  changed outside the application, is `{:error, :integrity}`, with a line in the log.
  """
  @spec fetch_for_verification(term) ::
          {:ok, AccessKey.t()} | :error | {:error, :unreadable | :integrity}
  def fetch_for_verification(key_id) when is_binary(key_id) do
    query =
      from(k in AccessKey,
        join: w in assoc(k, :workspace),
        join: o in assoc(k, :organisation),
        as: :organisation,
        left_join: n in assoc(k, :node),
        where: k.key_id == ^key_id and is_nil(k.revoked_at),
        where: is_nil(w.deletion_marked_at) and is_nil(o.deletion_marked_at),
        where: is_nil(k.node_id) or is_nil(n.deleted_at),
        preload: [workspace: w, node: n]
      )
      |> Apiary.Edition.active_organisations(:organisation)

    case Repo.one(query) do
      %AccessKey{} = access_key ->
        ids = LogMetadata.metadata(access_key.organisation_id, access_key.workspace_id)

        cond do
          not readable?(access_key) -> unreadable(key_id, ids)
          AccessKey.verify_integrity(access_key) != :ok -> tampered(key_id, ids)
          true -> {:ok, access_key}
        end

      nil ->
        :error
    end
  rescue
    ArgumentError -> unreadable(key_id, owner_ids(key_id))
  end

  def fetch_for_verification(_key_id), do: :error

  # A secret encrypted under another key does not raise when it is loaded: the cipher's
  # failure comes through as the atom `:error` in the field. A secret is a binary or nil.
  defp readable?(%AccessKey{secret_primary: primary, secret_secondary: secondary}) do
    (is_binary(primary) or is_nil(primary)) and (is_binary(secondary) or is_nil(secondary))
  end

  # The key id is public; nothing of the row is in the line but the organisation and
  # workspace ids, as metadata.
  defp unreadable(key_id, metadata) do
    Logger.error(
      "access key secret cannot be decrypted key_id=#{key_id}: " <>
        "APIARY_ENCRYPTION_SECRET is not the key the secret was encrypted with",
      metadata
    )

    {:error, :unreadable}
  end

  defp tampered(key_id, metadata) do
    Logger.error(
      "access key row does not match its integrity code key_id=#{key_id}: " <>
        "it was changed outside the application, or under another APIARY_ENCRYPTION_SECRET",
      metadata
    )

    {:error, :integrity}
  end

  # When loading the row raised, its ids are read again without the secrets, which are
  # what could not be read.

  defp owner_ids(key_id) do
    query =
      from k in AccessKey,
        where: k.key_id == ^key_id,
        select: {k.organisation_id, k.workspace_id}

    case Repo.one(query) do
      {organisation_id, workspace_id} -> LogMetadata.metadata(organisation_id, workspace_id)
      nil -> []
    end
  rescue
    _exception -> []
  end

  ## A node's keys

  @doc """
  code_ttl_minutes/0 is how long an enrolment code may be used once made: the
  `:code_ttl_minutes` of `Apiary.AccessKeys` in the configuration, held to 1 to
  #{@max_code_ttl_minutes}, the most the contract allows, and #{@default_code_ttl_minutes}
  when unset or not a whole number.
  """
  @spec code_ttl_minutes() :: pos_integer
  def code_ttl_minutes do
    case Keyword.get(Application.get_env(:apiary, __MODULE__, []), :code_ttl_minutes) do
      minutes when is_integer(minutes) -> minutes |> max(1) |> min(@max_code_ttl_minutes)
      _unset -> @default_code_ttl_minutes
    end
  end

  @doc """
  key_limits/0 is how many keys a node holds at most: `approved`, approved and not
  revoked, and `pending`, awaiting approval. A paste and an approval count them under the
  node's lock here; nothing here makes a pending key but the enrolment, which counts the
  pending limit under the same lock when it is built (the enrolment endpoint and the
  signed requests that follow).
  """
  @spec key_limits() :: %{approved: pos_integer, pending: pos_integer}
  def key_limits, do: %{approved: @approved_limit, pending: @pending_limit}

  @doc """
  list_for_node/2 is `node`'s keys, of the scope's workspace: those in use first, then the
  revoked; newest first within each, with the enrolment code each arrived by, if any.
  """
  @spec list_for_node(Scope.t(), Node.t()) :: [AccessKey.t()]
  def list_for_node(%Scope{} = scope, %Node{id: node_id}) do
    Repo.all(
      from k in in_workspace(AccessKey, scope),
        where: k.node_id == ^node_id,
        order_by: [asc: not is_nil(k.revoked_at), desc: k.inserted_at, desc: k.id],
        preload: [:enrolment_code]
    )
  end

  @doc """
  count_pending/1 is how many keys of the workspace's nodes in use await approval
  (`AccessKey.status/1`, `:pending`): for the sidebar's dot beside Nodes. One read.
  """
  @spec count_pending(Scope.t()) :: non_neg_integer
  def count_pending(%Scope{} = scope) do
    Repo.aggregate(
      from(k in in_workspace(AccessKey, scope),
        join: n in Node,
        on: n.id == k.node_id and is_nil(n.deleted_at),
        where: is_nil(k.revoked_at) and is_nil(k.approved_at) and not is_nil(k.public_key)
      ),
      :count,
      telemetry_options: [sidebar: true]
    )
  end

  @doc """
  list_enrolment_codes/2 is `node`'s outstanding enrolment codes, neither used, nor
  cancelled, nor expired, newest first. A code itself is never among what they hold.
  """
  @spec list_enrolment_codes(Scope.t(), Node.t()) :: [EnrolmentCode.t()]
  def list_enrolment_codes(%Scope{} = scope, %Node{id: node_id}) do
    now = DateTime.utc_now()

    Repo.all(
      from c in in_workspace(EnrolmentCode, scope),
        where: c.node_id == ^node_id and is_nil(c.used_at) and is_nil(c.cancelled_at),
        where: c.expires_at > ^now,
        order_by: [desc: c.inserted_at, desc: c.id]
    )
  end

  @doc """
  create_enrolment_code/3 makes an enrolment code for `node` (`access_key.create_code`,
  owners and admins), with the settings of the key it brings from `attrs`: its
  stored-secrets flag, `allow_secrets`, off unless set, and a `label_hint`. The code
  expires after `code_ttl_minutes/0`.

  Returns `{:ok, code_row, code}`, with the code in clear, `qec_` and 26 characters, this
  once: it is never stored. Otherwise `{:error, changeset}`, `{:error, :forbidden}`, or
  `{:error, :not_found}` for a node deleted or not the workspace's.
  """
  @spec create_enrolment_code(Scope.t(), Node.t(), map) ::
          {:ok, EnrolmentCode.t(), String.t()}
          | {:error, Ecto.Changeset.t() | Access.reason()}
  def create_enrolment_code(%Scope{user: user} = scope, %Node{} = node, attrs) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"access_key.create_code", node),
           {:ok, node} <- lock_node(scope, node.id) do
        code = EnrolmentCode.generate()
        now = DateTime.utc_now()

        changeset =
          %EnrolmentCode{
            id: Ecto.UUID.generate(),
            organisation_id: node.organisation_id,
            workspace_id: node.workspace_id,
            node_id: node.id,
            created_by_id: user.id,
            code_sha256: EnrolmentCode.hash(code),
            expires_at: DateTime.add(now, code_ttl_minutes(), :minute)
          }
          |> EnrolmentCode.settings_changeset(attrs)
          |> EnrolmentCode.put_integrity()

        with {:ok, row} <- Repo.insert(changeset),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"access_key.create_code", node, %{
                 after: %{
                   code_id: row.id,
                   allow_secrets: row.allow_secrets,
                   label_hint: row.label_hint,
                   expires_at: row.expires_at
                 }
               }) do
          {:ok, {row, code}}
        end
      end
    end)
    |> case do
      {:ok, {row, code}} -> {:ok, row, code}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  cancel_code/2 cancels an outstanding enrolment code (`access_key.cancel_code`, owners
  and admins): no machine enrols with it from then on. Cancelling a cancelled or expired
  code changes nothing; a used one is `{:error, :used}`. `{:error, :not_found}` for a code
  of another workspace, or of a deleted node.
  """
  @spec cancel_code(Scope.t(), EnrolmentCode.t()) ::
          {:ok, EnrolmentCode.t()} | {:error, :used | Access.reason()}
  def cancel_code(%Scope{} = scope, %EnrolmentCode{id: id, node_id: node_id} = code) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"access_key.cancel_code", code),
           {:ok, node} <- lock_node(scope, node_id),
           %EnrolmentCode{node_id: ^node_id} = current <-
             Repo.one(
               from c in in_workspace(EnrolmentCode, scope),
                 where: c.id == ^id,
                 lock: "FOR UPDATE"
             ) || {:error, :not_found} do
        cond do
          current.used_at != nil ->
            {:error, :used}

          not EnrolmentCode.outstanding?(current, DateTime.utc_now()) ->
            {:ok, current}

          true ->
            with {:ok, cancelled} <-
                   current
                   |> Ecto.Changeset.change(cancelled_at: DateTime.utc_now())
                   |> EnrolmentCode.put_integrity()
                   |> Repo.update(),
                 {:ok, _entry} <-
                   Audit.record(Repo, scope, :"access_key.cancel_code", node, %{
                     before: %{cancelled_at: nil},
                     after: %{cancelled_at: cancelled.cancelled_at},
                     details: %{code_id: cancelled.id}
                   }) do
              {:ok, cancelled}
            end
        end
      else
        %EnrolmentCode{} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  change_new_key/1 is the changeset of a key to paste, for the form that adds one: its
  label and stored-secrets flag.
  """
  @spec change_new_key(map) :: Ecto.Changeset.t()
  def change_new_key(attrs \\ %{}), do: AccessKey.insert_changeset(%AccessKey{}, attrs)

  @doc """
  add_access_key/3 adds a key to `node` by its public key (`access_key.add`, owners and
  admins), approved at once, since an owner or an admin entered it. `attrs`:
  `public_key`, the raw 32-byte Ed25519 public key in base64url without padding, as
  `qory access-key create` prints it; `label`; and `allow_secrets`, the stored-secrets
  flag, fixed from then on.

  The key passes the key checks (`Apiary.Contract.Ed25519`) and is not in the ledger,
  whatever its state there, or the changeset says "this key cannot be used" of it,
  whatever the reason. `{:ok, key}`; `{:error, changeset}`; `{:error, :key_limit}` while
  the node holds two keys, approved or awaiting approval; `{:error, :forbidden}`; or
  `{:error, :not_found}` for a node deleted or not the workspace's.
  """
  @spec add_access_key(Scope.t(), Node.t(), map) ::
          {:ok, AccessKey.t()} | {:error, Ecto.Changeset.t() | :key_limit | Access.reason()}
  def add_access_key(%Scope{user: user} = scope, %Node{} = node, attrs) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"access_key.add", node),
           {:ok, node} <- lock_node(scope, node.id),
           :ok <- within_limit(node, :add) do
        now = DateTime.utc_now()

        key = %AccessKey{
          id: Ecto.UUID.generate(),
          organisation_id: node.organisation_id,
          workspace_id: node.workspace_id,
          node_id: node.id,
          key_id: AccessKey.generate_key_id(),
          created_by_id: user.id,
          arrived_by: :paste,
          received_at: now,
          approved_at: now,
          approved_by_id: user.id
        }

        changeset = AccessKey.insert_changeset(key, attrs)

        with {:ok, public_key} <- received_key(changeset, attr(attrs, :public_key)),
             changeset =
               changeset
               |> Ecto.Changeset.put_change(:public_key, public_key)
               |> AccessKey.put_integrity(),
             {:ok, _valid} <- Ecto.Changeset.apply_action(changeset, :insert),
             :ok <- enter_in_ledger(changeset, public_key, :current, now),
             {:ok, added} <- Repo.insert(changeset),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"access_key.add", added, %{
                 after: %{
                   label: added.label,
                   key_id: added.key_id,
                   fingerprint: AccessKey.fingerprint(added),
                   allow_secrets: added.allow_secrets,
                   arrived_by: added.arrived_by
                 },
                 details: %{node_id: node.public_id}
               }) do
          {:ok, added}
        end
      end
    end)
  end

  # The public key of a paste, checked: any refusal, a key the checks or the ledger
  # refuse, is one error on the changeset, whatever the reason.
  defp received_key(changeset, value) do
    case Ed25519.decode_public_key(value) do
      {:ok, public_key} -> {:ok, public_key}
      {:error, _refusal} -> {:error, AccessKey.refuse_public_key(changeset)}
    end
  end

  # One public key, one access key, ever: a key already in the ledger, in any state, is
  # refused as an invalid one is. A row conflicting on the key id cannot happen, since key
  # ids are fresh, and would raise.
  defp enter_in_ledger(changeset, public_key, state, now) do
    entry = %{
      public_key: public_key,
      key_id: Ecto.Changeset.get_field(changeset, :key_id),
      state: state,
      received_at: now,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(PublicKey, [entry], on_conflict: :nothing, conflict_target: :public_key) do
      {1, _} -> :ok
      {0, _} -> {:error, AccessKey.refuse_public_key(changeset)}
    end
  end

  @doc """
  approve/2 approves a node's key that awaits approval (`access_key.approve`, owners and
  admins): it verifies requests from then on, with the stored-secrets flag it was made
  with. `{:ok, key}`; `{:error, :key_limit}` while the node holds two approved keys;
  `{:error, :not_pending}` for a key approved, rejected or revoked already;
  `{:error, :integrity}` for a row that does not match its integrity code, changed
  outside the application; `{:error, :forbidden}`; or `{:error, :not_found}`.
  """
  @spec approve(Scope.t(), AccessKey.t()) ::
          {:ok, AccessKey.t()}
          | {:error, :key_limit | :not_pending | :integrity | Access.reason()}
  def approve(%Scope{user: user} = scope, %AccessKey{} = access_key) do
    change_node_key(scope, :"access_key.approve", access_key, fn node, current ->
      with :ok <- intact(current),
           :pending <- AccessKey.status(current),
           :ok <- within_limit(node, :approve) do
        now = DateTime.utc_now()

        with {:ok, approved} <-
               current
               |> Ecto.Changeset.change(approved_at: now, approved_by_id: user.id)
               |> AccessKey.put_integrity()
               |> Repo.update(),
             :ok <- approve_in_ledger(approved),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"access_key.approve", approved, %{
                 before: %{approved_at: nil},
                 after: %{approved_at: approved.approved_at},
                 details: %{
                   fingerprint: AccessKey.fingerprint(approved),
                   allow_secrets: approved.allow_secrets,
                   arrived_by: approved.arrived_by
                 }
               }) do
          {:ok, approved}
        end
      else
        status when is_atom(status) and status in [:active, :revoked, :rotating] ->
          {:error, :not_pending}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  reject/2 rejects a node's key that awaits approval (`access_key.reject`, owners and
  admins): it never verifies a request, and its public key becomes a tombstone in the
  ledger, refused wherever it is posted again. `{:ok, key}`; `{:error, :not_pending}` for
  a key approved, rejected or revoked already; `{:error, :forbidden}`; or
  `{:error, :not_found}`.
  """
  @spec reject(Scope.t(), AccessKey.t()) ::
          {:ok, AccessKey.t()} | {:error, :not_pending | Access.reason()}
  def reject(%Scope{} = scope, %AccessKey{} = access_key) do
    change_node_key(scope, :"access_key.reject", access_key, fn node, current ->
      case AccessKey.status(current) do
        :pending -> retire(scope, node, current, :"access_key.reject", :rejected)
        _other -> {:error, :not_pending}
      end
    end)
  end

  @doc """
  revoke_node_keys/3 revokes every key of `node` in use, and cancels its outstanding
  enrolment codes, inside the caller's transaction, which holds the node's row
  `FOR UPDATE` and has asked what it does of `Apiary.Access`: the deletion of the node
  (`Apiary.Nodes.delete_node/2`). Each key's public key becomes a tombstone for `reason`,
  and each key leaves an entry of `access_key.revoke`, a key awaiting approval among
  them. Returns the key ids revoked, or `{:error, changeset}`.
  """
  @spec revoke_node_keys(Scope.t(), Node.t(), PublicKey.reason()) ::
          {:ok, [String.t()]} | {:error, Ecto.Changeset.t()}
  def revoke_node_keys(%Scope{} = scope, %Node{id: node_id} = node, reason) do
    keys =
      Repo.all(
        from k in in_workspace(AccessKey, scope),
          where: k.node_id == ^node_id and is_nil(k.revoked_at),
          order_by: [asc: k.id],
          lock: "FOR UPDATE"
      )

    with {:ok, key_ids} <- revoke_each(scope, node, keys, reason),
         :ok <- cancel_codes(scope, node) do
      {:ok, key_ids}
    end
  end

  defp revoke_each(scope, node, keys, reason) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, key_ids} ->
      case retire(scope, node, key, :"access_key.revoke", reason) do
        {:ok, revoked} -> {:cont, {:ok, [revoked.key_id | key_ids]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, key_ids} -> {:ok, Enum.reverse(key_ids)}
      error -> error
    end
  end

  defp cancel_codes(scope, %Node{id: node_id}) do
    now = DateTime.utc_now()

    Repo.all(
      from c in in_workspace(EnrolmentCode, scope),
        where: c.node_id == ^node_id and is_nil(c.used_at) and is_nil(c.cancelled_at),
        lock: "FOR UPDATE"
    )
    |> Enum.reduce_while(:ok, fn code, :ok ->
      code
      |> Ecto.Changeset.change(cancelled_at: now)
      |> EnrolmentCode.put_integrity()
      |> Repo.update()
      |> case do
        {:ok, _cancelled} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # A key retired, by revocation, rejection or its node's deletion: revoked from now on,
  # by the scope's person, its public key a tombstone, and the entry of `action`.
  defp retire(%Scope{user: user} = scope, node, %AccessKey{} = current, action, reason) do
    now = DateTime.utc_now()

    with {:ok, retired} <-
           current
           |> Ecto.Changeset.change(revoked_at: now, revoked_by_id: user && user.id)
           |> AccessKey.put_integrity()
           |> Repo.update(),
         :ok <- tombstone_in_ledger(retired, reason, now),
         {:ok, _entry} <-
           Audit.record(Repo, scope, action, retired, %{
             before: %{revoked_at: nil},
             after: %{revoked_at: retired.revoked_at},
             details: %{
               fingerprint: AccessKey.fingerprint(retired),
               reason: reason,
               node_id: node.public_id
             }
           }) do
      {:ok, retired}
    end
  end

  # An approval moves the key's own row of the ledger, pending, to current, in its
  # transaction. A row missing, of another key or not pending is a ledger changed outside
  # the application, and the approval does not trust it.
  defp approve_in_ledger(%AccessKey{public_key: public_key, key_id: key_id} = key) do
    query =
      from p in PublicKey,
        where: p.public_key == ^public_key and p.key_id == ^key_id and p.state == :pending

    case Repo.update_all(query, set: [state: :current, updated_at: DateTime.utc_now()]) do
      {1, _} -> :ok
      {0, _} -> tampered(key.key_id, LogMetadata.metadata(key.organisation_id, key.workspace_id))
    end
  end

  # A retirement makes the public key a tombstone whatever the ledger holds for it: a row
  # missing, or naming another key, must never stop a key, perhaps a leaked one, from
  # being revoked. The row is written if it is missing, and its state, time and reason
  # replaced if it is there, under the key id it already names.
  defp tombstone_in_ledger(%AccessKey{} = key, reason, now) do
    entry = %{
      public_key: key.public_key,
      key_id: key.key_id,
      state: :tombstone,
      received_at: key.received_at || now,
      retired_at: now,
      retired_reason: reason,
      inserted_at: now,
      updated_at: now
    }

    {1, _} =
      Repo.insert_all(PublicKey, [entry],
        on_conflict: {:replace, [:state, :retired_at, :retired_reason, :updated_at]},
        conflict_target: :public_key
      )

    :ok
  end

  @doc """
  retire_public_keys/2 makes a tombstone, `workspace_deleted`, of the ledger's row of every
  node's key of an organisation, or of one of its workspaces, that is not one already:
  the purge (`Apiary.Deletion`) calls it before it deletes the keys, so the ledger keeps
  their public keys retired once the rows are gone. Safe to call again. Returns how many
  rows it retired.
  """
  @spec retire_public_keys(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: non_neg_integer
  def retire_public_keys(organisation_id, workspace_id) do
    keys =
      from k in AccessKey,
        where: k.organisation_id == ^organisation_id and not is_nil(k.public_key),
        select: k.key_id

    keys = if workspace_id, do: where(keys, [k], k.workspace_id == ^workspace_id), else: keys
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(p in PublicKey, where: p.state != :tombstone and p.key_id in subquery(keys)),
        set: [
          state: :tombstone,
          retired_at: now,
          retired_reason: :workspace_deleted,
          updated_at: now
        ]
      )

    count
  end

  # Asks `action` of the caller's membership as it is now, then hands `fun` the key's
  # node, in use and locked, and the key as it is now, a node's key of the scope's
  # workspace, locked after it, for the rest of the transaction.
  defp change_node_key(%Scope{} = scope, action, %AccessKey{id: id} = access_key, fun) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, action, access_key),
           %AccessKey{node_id: node_id} when is_binary(node_id) <-
             Repo.one(
               from k in in_workspace(AccessKey, scope),
                 where: k.id == ^id,
                 select: struct(k, [:id, :node_id])
             ) || {:error, :not_found},
           {:ok, node} <- lock_node(scope, node_id),
           %AccessKey{} = current <-
             Repo.one(
               from k in in_workspace(AccessKey, scope),
                 where: k.id == ^id and k.node_id == ^node_id,
                 lock: "FOR UPDATE"
             ) || {:error, :not_found} do
        fun.(node, current)
      else
        %AccessKey{} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp intact(%AccessKey{} = key) do
    case AccessKey.verify_integrity(key) do
      :ok ->
        :ok

      {:error, _reason} ->
        ids = LogMetadata.metadata(key.organisation_id, key.workspace_id)
        tampered(key.key_id, ids)
    end
  end

  # A node in use of the scope's workspace, locked: every change of its keys and codes
  # takes it first, so the limits count every change before them.
  defp lock_node(%Scope{} = scope, node_id) do
    query =
      from n in in_workspace(Node, scope),
        where: n.id == ^node_id and is_nil(n.deleted_at),
        lock: "FOR UPDATE"

    case Repo.one(query) do
      %Node{} = node -> {:ok, node}
      nil -> {:error, :not_found}
    end
  end

  # A paste is refused while the node holds two keys, approved or awaiting approval,
  # since it is approved at once; an approval while it holds two approved ones.
  defp within_limit(%Node{id: node_id}, purpose) do
    counts =
      Repo.one(
        from k in AccessKey,
          where: k.node_id == ^node_id and is_nil(k.revoked_at),
          select: %{
            approved: filter(count(k.id), not is_nil(k.approved_at)),
            pending: filter(count(k.id), is_nil(k.approved_at))
          }
      )

    full? =
      case purpose do
        :add -> counts.approved + counts.pending >= @approved_limit
        :approve -> counts.approved >= @approved_limit
      end

    if full?, do: {:error, :key_limit}, else: :ok
  end

  defp in_workspace(queryable, %Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from r in queryable,
      where: r.organisation_id == ^organisation_id and r.workspace_id == ^workspace_id
  end

  defp attr(attrs, name) when is_map(attrs),
    do: Map.get(attrs, name, Map.get(attrs, Atom.to_string(name)))

  @doc "Records a use: `last_used_at` now, plus `last_runner_version` and `last_contract_version` from `attrs`."
  def touch(%AccessKey{} = access_key, attrs) do
    access_key |> AccessKey.touch_changeset(attrs) |> Repo.update()
  end

  @doc """
  Records a delivery to the events endpoint: `last_used_at`, the runner and
  contract versions when the request named them (a request that named none
  leaves what is recorded), and `last_heartbeat_at` when the delivery held a new
  heartbeat, never moving it backwards. One `UPDATE`, without reading the row.
  """
  def touch_delivery(%AccessKey{id: id}, attrs) do
    set =
      [
        last_used_at: attrs[:last_used_at] || DateTime.utc_now(),
        last_runner_version: attrs[:last_runner_version],
        last_contract_version: attrs[:last_contract_version]
      ]
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)

    query = from(k in AccessKey, where: k.id == ^id)

    query =
      case attrs[:last_heartbeat_at] do
        %DateTime{} = at ->
          # GREATEST ignores a null: the first heartbeat sets the column.
          from k in query,
            update: [
              set: [
                last_heartbeat_at:
                  fragment("GREATEST(?, ?)", k.last_heartbeat_at, type(^at, :utc_datetime_usec))
              ]
            ]

        _ ->
          query
      end

    Repo.update_all(query, set: set)
    :ok
  end

  @doc "The `server` block of the runner file for this key."
  def server_block(%AccessKey{key_id: key_id}, secret, base_url) when is_binary(secret) do
    """
    apiVersion: qory.dev/v1alpha1
    server:
      url: #{base_url}
      access_key: #{key_id}
      secret: #{secret}
    """
  end
end

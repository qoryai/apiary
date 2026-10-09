defmodule Apiary.AccessKeys do
  @moduledoc """
  Access keys: a workspace's credentials for the server contract
  (`Apiary.AccessKeys.AccessKey`). Each has one Ed25519 public key and belongs to one node
  or node pool of the workspace (`Apiary.Nodes`); a node holds several over its life.
  Owners and admins alone manage them:

    * an **enrolment code** (`create_enrolment_code/3`, `access_key.create_code`) is
      single use and expires after `code_ttl_minutes/0`; it carries the settings the key
      it brings gets, and is returned once, kept only as its SHA-256; an outstanding one
      is cancelled with `cancel_code/2` (`access_key.cancel_code`);
    * a machine **enrols** a key with a code (`enrol/2`, the runner contract's
      enrolment): the code is the approval, so the key is active as it is made, while
      the code's maker is still an owner or an admin of its workspace; the code is the
      authority, and the key itself the actor of its entry, `access_key.add`;
    * a key **made in a browser** (`add_access_key/3`, `access_key.add`) is added by its
      public key alone, active as it is added, marked `arrived_by: :browser`: its secret
      stayed in the browser that made it, and Apiary never receives it;
    * a key is **revoked** (`revoke_access_key/2`, `access_key.revoke`), and every key of
      a deleted node with it (`Apiary.Nodes.delete_node/2`).

  A node holds at most two keys at a time: a key made in a browser or an enrolment is
  refused while it holds two, `{:error, :key_limit}`. A key's label is unique among the node's keys in
  use. Its stored-secrets flag is fixed when it is made; there is no rotation of a key: to
  change the flag, or replace a lost key, a new key is added for the same node, and the
  old one revoked.

  **The checks.** Every public key received passes the key checks of
  `Apiary.Contract.Ed25519` and is not in the ledger (`Apiary.AccessKeys.PublicKey`),
  where every key's public key is written in the transaction that makes the key and
  stays, a tombstone once the key is retired: one public key, one access key, ever. A key
  refused by either gets one answer, "this key cannot be used", so a refusal reveals
  nothing about other keys; at enrolment the contract has the checks' refusal sent
  unsigned and the ledger's signed, and only a request whose proof verifies under the key,
  made by the key's holder, gets as far as the ledger. A key's row and an enrolment code's carry an integrity code
  (`Apiary.Integrity`), written with every change and checked before the row is trusted:
  `fetch_for_verification/1` refuses a key whose row does not match it.

  **Locks.** A change of a node's keys locks the node's row `FOR UPDATE`, then the key's
  or the code's, so the limit counts every change before it.

  Every change of a key leaves an audit entry (`Apiary.Audit`) in its transaction: its
  arrival and revocation, with its fingerprint; a code's making and cancelling, on its
  node. Never a secret, nor a code.

  **A key enrolled is announced** on its node's topic (`topic/2`), once its transaction
  has committed, so that the page that showed the command sees the machine connect.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Audit, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Contract.{Ed25519, Enrolment}
  alias Apiary.LogMetadata
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Workspace, Organisation}
  alias Apiary.Runs.RateLimit

  @code_ttl_minutes 15
  @key_limit 2
  # A code's own limit at enrolment, as `Apiary.Runs.RateLimit` counts it: requests a
  # second, and at once.
  @code_limit [rate: 1, burst: 5]

  defguardp key_in_scope(scope, access_key)
            when access_key.organisation_id == scope.organisation.id and
                   access_key.workspace_id == scope.workspace.id

  def change_access_key(%AccessKey{} = access_key, attrs \\ %{}) do
    AccessKey.changeset(access_key, attrs)
  end

  @doc """
  Revokes a key (`access_key.revoke`, owners and admins): verification fails from now on,
  and its public key becomes a tombstone in the ledger. Revoking a revoked key changes
  nothing.
  """
  @spec revoke_access_key(Scope.t(), AccessKey.t()) ::
          {:ok, AccessKey.t()} | {:error, Access.reason()}
  def revoke_access_key(%Scope{} = scope, %AccessKey{} = access_key)
      when key_in_scope(scope, access_key) do
    change_node_key(scope, :"access_key.revoke", access_key, fn node, current ->
      case AccessKey.status(current) do
        :revoked ->
          {:ok, current}

        :active ->
          retire(scope, node, current, :"access_key.revoke", :revoked)
      end
    end)
  end

  @doc """
  The key behind a key id, for request verification, with its workspace, read in the same
  query (its domain names a run's target, `Apiary.Policy.Serving`), and its node.
  `:error` for a key id the workspace does not hold or has revoked, for a key of a deleted
  node, for a key of a workspace or an organisation marked for deletion
  (`Apiary.Deletion`), which answers as a revoked key does until its deletion is
  cancelled, and for a key of an organisation
  the edition stopped (`c:Apiary.Edition.active_organisations/2`), which answers so until it
  is in use again: a key is a workspace's, not a person's, so a suspended membership or an
  account out of use leaves the keys working.

  Its integrity code is checked first: a row that does not match it, changed outside the
  application, is `{:error, :integrity}`, with a line in the log.
  """
  @spec fetch_for_verification(term) :: {:ok, AccessKey.t()} | :error | {:error, :integrity}
  def fetch_for_verification(key_id) when is_binary(key_id) do
    query =
      from(k in AccessKey,
        join: w in assoc(k, :workspace),
        join: o in assoc(k, :organisation),
        as: :organisation,
        join: n in assoc(k, :node),
        where: k.key_id == ^key_id and is_nil(k.revoked_at),
        where: is_nil(w.deletion_marked_at) and is_nil(o.deletion_marked_at),
        where: is_nil(n.deleted_at),
        preload: [workspace: w, node: n]
      )
      |> Apiary.Edition.active_organisations(:organisation)

    case Repo.one(query) do
      %AccessKey{} = access_key ->
        case AccessKey.verify_integrity(access_key) do
          :ok ->
            {:ok, access_key}

          {:error, _reason} ->
            ids = LogMetadata.metadata(access_key.organisation_id, access_key.workspace_id)
            tampered(key_id, ids)
        end

      nil ->
        :error
    end
  end

  def fetch_for_verification(_key_id), do: :error

  # The key id is public; nothing of the row is in the line but the organisation and
  # workspace ids, as metadata.
  defp tampered(key_id, metadata) do
    Logger.error(
      "access key row does not match its integrity code key_id=#{key_id}: " <>
        "it was changed outside the application, or under another APIARY_ENCRYPTION_SECRET",
      metadata
    )

    {:error, :integrity}
  end

  ## Codes, keys and their limits

  @doc """
  code_ttl_minutes/0 is how long an enrolment code may be used once made:
  #{@code_ttl_minutes} minutes, fixed, which no configuration changes.
  """
  @spec code_ttl_minutes() :: pos_integer
  def code_ttl_minutes, do: @code_ttl_minutes

  @doc """
  key_variable/1 is the variable that names `key` to a runner that is given its key in
  variables rather than in the runner file: `QORY_ACCESS_KEY_ID`, the key's id. It is the
  key's part of what a runner is given, and nothing of it is secret. The key's secret,
  `QORY_ACCESS_KEY_SECRET`, is not Apiary's to give; the server's part is
  `server_variable/1`.
  """
  @spec key_variable(AccessKey.t()) :: {String.t(), String.t()}
  def key_variable(%AccessKey{key_id: key_id}) when is_binary(key_id),
    do: {"QORY_ACCESS_KEY_ID", key_id}

  @doc """
  server_variable/1 is the server's part of a runner's variables, the same for every key,
  node, workspace and organisation of the instance: `QORY_APIARY_PUBLIC_KEY`, the pin as
  JSON. `pin` is the server's `apiary_public_key` list
  (`Apiary.SigningKey.apiary_public_key/0`), the instance's own signing key: no key is
  asked for.
  """
  @spec server_variable([%{required(String.t()) => String.t()}, ...]) :: {String.t(), String.t()}
  def server_variable(pin \\ Apiary.SigningKey.apiary_public_key()) do
    json =
      Enum.map(pin, fn %{"alg" => alg, "public_key" => public_key} ->
        Jason.OrderedObject.new([{"alg", alg}, {"public_key", public_key}])
      end)

    {"QORY_APIARY_PUBLIC_KEY", Jason.encode!(json)}
  end

  @doc """
  key_line/1 is `key`'s line of the runner file's `server` section, `access_key_id`,
  indented as it sits under `server:`. The key's secret is the machine's alone.
  """
  @spec key_line(AccessKey.t()) :: String.t()
  def key_line(%AccessKey{key_id: key_id}) when is_binary(key_id),
    do: "  access_key_id: #{key_id}"

  @doc """
  server_lines/2 is the server's lines of the runner file's `server` section, the same for
  every key of the instance, each indented as it sits under `server:`: `url`, the line of
  `base_url`, the address machines reach the server at; and `public_key`, the lines of
  `apiary_public_key`, the pin, in YAML's flow form, one line per key. `pin` is
  `Apiary.SigningKey.apiary_public_key/0`'s list: no key is asked for.
  """
  @spec server_lines(String.t(), [%{required(String.t()) => String.t()}, ...]) ::
          %{url: String.t(), public_key: [String.t(), ...]}
  def server_lines(base_url, pin \\ Apiary.SigningKey.apiary_public_key())
      when is_binary(base_url) do
    pins =
      Enum.map(pin, fn %{"alg" => alg, "public_key" => public_key} ->
        "    - {alg: #{alg}, public_key: #{public_key}}"
      end)

    %{url: "  url: #{base_url}", public_key: ["  apiary_public_key:" | pins]}
  end

  @doc """
  key_limit/0 is how many keys a node holds at most at a time, not revoked:
  #{@key_limit}. A key made in a browser (`add_access_key/3`) and an enrolment (`enrol/2`)
  count them under the node's lock.
  """
  @spec key_limit() :: pos_integer
  def key_limit, do: @key_limit

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
  list_workspace_node_keys/1 is the keys of the scope's workspace's nodes and node pools in
  use, not revoked (so active), each with its node, newest first.
  """
  @spec list_workspace_node_keys(Scope.t()) :: [AccessKey.t()]
  def list_workspace_node_keys(%Scope{} = scope) do
    Repo.all(
      from k in in_workspace(AccessKey, scope),
        join: n in assoc(k, :node),
        where: is_nil(k.revoked_at) and is_nil(n.deleted_at),
        order_by: [desc: k.inserted_at, desc: k.id],
        preload: [node: n]
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
  of another workspace, or of a deleted node. A code cancelled now is announced on its
  node's `topic/2` once the transaction has committed.
  """
  @spec cancel_code(Scope.t(), EnrolmentCode.t()) ::
          {:ok, EnrolmentCode.t()} | {:error, :used | Access.reason()}
  def cancel_code(%Scope{} = scope, %EnrolmentCode{} = code) do
    with {:ok, {cancelled, row}} <- cancel_now(scope, code) do
      # Announced once the transaction has committed, and only for a code cancelled now.
      if cancelled, do: broadcast_cancelled(row)
      {:ok, row}
    end
  end

  # The cancel, in one transaction: whether it cancelled the code now, and the code.
  defp cancel_now(scope, %EnrolmentCode{id: id, node_id: node_id} = code) do
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
            {:ok, {false, current}}

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
              {:ok, {true, cancelled}}
            end
        end
      else
        %EnrolmentCode{} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  change_new_key/1 is the changeset of a key to make in a browser, for the form that
  makes one: its label.
  """
  @spec change_new_key(map) :: Ecto.Changeset.t()
  def change_new_key(attrs \\ %{}), do: AccessKey.insert_changeset(%AccessKey{}, attrs)

  @doc """
  add_access_key/3 adds a key made in the reader's browser to `node` by its public key
  (`access_key.add`, owners and admins), active at once, marked `arrived_by: :browser`:
  the Access key tab's Generate a key, which sent the public key alone and kept the
  secret. `attrs`: `public_key`, the raw 32-byte Ed25519 public key in base64url without
  padding; `label`; and `allow_secrets`, the stored-secrets flag, fixed from then on.

  The key passes the key checks (`Apiary.Contract.Ed25519`) and is not in the ledger,
  whatever its state there, or the changeset says "this key cannot be used" of it,
  whatever the reason. `{:ok, key}`; `{:error, changeset}`; `{:error, :key_limit}` while
  the node holds two keys; `{:error, :forbidden}`; or `{:error, :not_found}` for a node
  deleted or not the workspace's.
  """
  @spec add_access_key(Scope.t(), Node.t(), map) ::
          {:ok, AccessKey.t()} | {:error, Ecto.Changeset.t() | :key_limit | Access.reason()}
  def add_access_key(%Scope{user: user} = scope, %Node{} = node, attrs) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"access_key.add", node),
           {:ok, node} <- lock_node(scope, node.id),
           :ok <- within_limit(node) do
        now = DateTime.utc_now()

        key = %AccessKey{
          id: Ecto.UUID.generate(),
          organisation_id: node.organisation_id,
          workspace_id: node.workspace_id,
          node_id: node.id,
          key_id: AccessKey.generate_key_id(),
          created_by_id: user.id,
          arrived_by: :browser,
          received_at: now
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

  # The public key a browser sent, checked: any refusal, a key the checks or the ledger
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
  enrol/2 redeems an enrolment code for the key a machine enrols with it, the runner
  contract's enrolment (`Apiary.Contract.Enrolment`, `ApiaryWeb.Contract.EnrolmentController`):
  the code is the authority, so no person's scope is asked. It answers in the contract's
  order, each step only once every step before it passed.

  **1. The code is accepted**, or `{:error, :unauthorized}`, whatever the reason: the
  request's timestamp is within 300 seconds of `now`, either way; the code carries exactly
  the fingerprint of the instance's signing key (`Apiary.SigningKey.fingerprint/0`); its
  SHA-256 is an enrolment code's, of a workspace and an organisation in use (neither
  marked for deletion, nor stopped by the edition); **its maker is still an owner or an
  admin** of its workspace: their account in use, their membership neither suspended nor
  removed nor lowered to member, so that they could make the code now
  (`access_key.create_code`, `Apiary.Access`); its node is in use; its row matches its
  integrity code; and it is neither cancelled nor expired, and either not yet used or
  used by this very public key, whose key is still in use and intact (the repeat, below).
  The maker's membership is read `FOR SHARE`, in the lock order of docs/access.md, so a
  change of it waits for the enrolment, or comes first and is seen; then the node's row is
  locked `FOR UPDATE`, then the code's, so two machines never redeem one code, and the
  limit counts every change before it.

  **2. The key is proven**, or `{:error, :key_unproven}`: the key checks
  (`Apiary.Contract.Ed25519.decode_public_key/1`, the published fixture keys among them)
  first, then the proof under the key. The caller answers this unsigned: nothing is signed
  for a proof that does not verify under a key the checks pass, such as a proof under a
  key of small order, which plain verification accepts for any message.

  **3. The code is within its limit**, `code_limit` (`rate` and `burst`, as
  `Apiary.Runs.RateLimit` counts them, 1 and 5 unless given), or
  `{:error, {:rate_limited, retry_after_seconds}}`.

  **4. The key is new**: a public key in the ledger already, in any state, that of another
  access key or a revoked one, is `{:error, :key_invalid}`, as a browser key's is.

  **5. The node has room**: a node that holds two keys is `{:error, :key_limit}`.

  Every refusal changes nothing: the code stays as it was. Then **the key is made**,
  active, on the code's node, with the code's stored-secrets flag, its label the code's
  label hint, else the name the machine sent, with `-2`, `-3` and on after it while the
  node holds a key in use of that label; its public key enters the ledger, current; the
  code is used, by the key's id and public key; and the key itself, as the actor, from
  `origin`, leaves the entry `access_key.add`, with `arrived_by` `code`. `{:ok, key}`,
  with its node.

  **A repeat** of a used code is the same answer again: a request whose code made a key,
  with the same public key, a proof that verifies and a fresh timestamp, while the code
  would not have expired, its maker is still an owner or an admin and the key is not
  revoked, is `{:ok, key}` for that key, as it is now, once within the code's limit, and
  changes nothing; so a machine whose answer was lost may ask again. Any other key on a
  used code is `{:error, :unauthorized}`. The public keys are compared in constant time.

  `opts`: `now`, the time it is (the current time); `fingerprint`, the signing key's
  fingerprint (`Apiary.SigningKey.fingerprint/0`); `origin`, where the request came from,
  for the audit entry (`ApiaryWeb.Origin`); `code_limit`, the code's limit.
  """
  @spec enrol(Enrolment.t(), keyword) ::
          {:ok, AccessKey.t()}
          | {:error,
             :unauthorized
             | :key_unproven
             | {:rate_limited, pos_integer}
             | :key_invalid
             | :key_limit}
  def enrol(%Enrolment{} = request, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    fingerprint = Keyword.get_lazy(opts, :fingerprint, &Apiary.SigningKey.fingerprint/0)
    code_limit = Keyword.merge(@code_limit, Keyword.get(opts, :code_limit, []))

    with true <- Enrolment.fresh?(request, now) || {:error, :unauthorized},
         true <- Enrolment.issued_under?(request, fingerprint) || {:error, :unauthorized},
         %EnrolmentCode{} = found <- find_code(request.code_head) || {:error, :unauthorized},
         {:ok, {made, key}} <-
           Repo.transact(fn ->
             redeem(found, request, now, Keyword.get(opts, :origin), code_limit)
           end) do
      # Announced once the transaction has committed, never from inside it, and only for a
      # key made now: a repeat changes nothing, so it says nothing new.
      if made == :new, do: broadcast_enrolled(key)
      {:ok, key}
    end
  end

  @doc """
  topic/2 is the topic of one node's keys, of its workspace: `{:key_enrolled, %{key_id:,
  node_id:}}` once a machine has enrolled a key on the node with a code (`enrol/2`), after
  the enrolment's transaction committed, and `{:code_cancelled, %{code_id:, node_id:}}`
  once a code of the node was cancelled (`cancel_code/2`), after that transaction
  committed. Each message carries ids alone, nothing secret: a subscriber reads the key
  or the codes again under its own scope.
  """
  @spec topic(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def topic(workspace_id, node_id), do: "access_keys:#{workspace_id}:#{node_id}"

  @doc "subscribe/2 subscribes the caller to `topic/2` of `node`, a node of the scope's workspace."
  @spec subscribe(Scope.t(), Node.t()) :: :ok | {:error, term}
  def subscribe(%Scope{workspace: %Workspace{id: workspace_id}}, %Node{
        id: node_id,
        workspace_id: workspace_id
      }),
      do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(workspace_id, node_id))

  @doc "unsubscribe/2 undoes `subscribe/2`."
  @spec unsubscribe(Scope.t(), Node.t()) :: :ok
  def unsubscribe(%Scope{workspace: %Workspace{id: workspace_id}}, %Node{id: node_id}),
    do: Phoenix.PubSub.unsubscribe(Apiary.PubSub, topic(workspace_id, node_id))

  defp broadcast_cancelled(%EnrolmentCode{} = code) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      topic(code.workspace_id, code.node_id),
      {:code_cancelled, %{code_id: code.id, node_id: code.node_id}}
    )
  end

  defp broadcast_enrolled(%AccessKey{} = key) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      topic(key.workspace_id, key.node_id),
      {:key_enrolled, %{key_id: key.key_id, node_id: key.node_id}}
    )
  end

  # The code by its SHA-256, of a workspace and an organisation in use, read without a
  # lock: its node is locked first, then the code again (`redeem/4`).
  defp find_code(head) do
    from(c in EnrolmentCode,
      join: w in assoc(c, :workspace),
      join: o in assoc(c, :organisation),
      as: :organisation,
      where: c.code_sha256 == ^EnrolmentCode.hash(head),
      where: is_nil(w.deletion_marked_at) and is_nil(o.deletion_marked_at)
    )
    |> Apiary.Edition.active_organisations(:organisation)
    |> Repo.one()
  end

  defp redeem(%EnrolmentCode{} = found, request, now, origin, code_limit) do
    with :ok <- maker_may_enrol(found),
         {:ok, node} <- lock_enrolling_node(found),
         {:ok, code} <- lock_code(found),
         true <- code.created_by_id == found.created_by_id || {:error, :unauthorized},
         {:ok, state} <- code_state(code, node, request, now),
         {:ok, public_key} <- proven(request),
         :ok <- within_code_limit(code, code_limit) do
      case state do
        :outstanding ->
          with {:ok, key} <- enrol_new(code, node, request, public_key, now, origin),
               do: {:ok, {:new, key}}

        {:used, key} ->
          {:ok, {:repeat, key}}
      end
    end
  end

  # The code is the approval of the key it brings only while its maker could make it now:
  # an owner or an admin of its workspace, their account in use and their membership
  # neither suspended, nor removed, nor lowered to member (`access_key.create_code`). Their
  # membership is read again `FOR SHARE`, with the organisation, the workspace and the
  # account before it, in the lock order of docs/access.md, before the node is locked: a
  # change of the maker's level, a suspension or a removal waits for the enrolment, or
  # comes first and refuses the code. A code whose maker's account is gone, or that names
  # none, is refused too.
  defp maker_may_enrol(%EnrolmentCode{created_by_id: maker_id} = code)
       when is_binary(maker_id) do
    with {:ok, scope} <-
           Apiary.Organisations.job_scope(code.organisation_id, code.workspace_id, maker_id),
         %Scope{user: %Apiary.Accounts.User{}} = scope <- Access.reload(scope, lock: :share),
         :ok <- Access.check(scope, :"access_key.create_code", code) do
      :ok
    else
      _refused -> {:error, :unauthorized}
    end
  end

  defp maker_may_enrol(%EnrolmentCode{}), do: {:error, :unauthorized}

  defp lock_enrolling_node(%EnrolmentCode{} = code) do
    query =
      from n in Node,
        where: n.id == ^code.node_id and is_nil(n.deleted_at),
        where:
          n.organisation_id == ^code.organisation_id and n.workspace_id == ^code.workspace_id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      %Node{} = node -> {:ok, Repo.preload(node, :workspace)}
      nil -> {:error, :unauthorized}
    end
  end

  # The code again, locked after its node, and checked against its integrity code: a row
  # changed outside the application is never redeemed.
  defp lock_code(%EnrolmentCode{id: id, node_id: node_id}) do
    query =
      from c in EnrolmentCode,
        where: c.id == ^id and c.node_id == ^node_id,
        lock: "FOR UPDATE"

    with %EnrolmentCode{} = code <- Repo.one(query) || {:error, :unauthorized},
         :ok <- intact_code(code) do
      {:ok, code}
    end
  end

  defp intact_code(%EnrolmentCode{} = code) do
    case EnrolmentCode.verify_integrity(code) do
      :ok ->
        :ok

      {:error, _reason} ->
        Logger.error(
          "enrolment code row does not match its integrity code code_id=#{code.id}: " <>
            "it was changed outside the application, or under another APIARY_ENCRYPTION_SECRET",
          LogMetadata.metadata(code.organisation_id, code.workspace_id)
        )

        {:error, :unauthorized}
    end
  end

  # Outstanding, or used by the very public key the request carries, whose key is still
  # in use and intact (the repeat); anything else, a code cancelled or expired among it,
  # is no code.
  defp code_state(%EnrolmentCode{} = code, node, request, now) do
    cond do
      code.cancelled_at != nil or DateTime.compare(code.expires_at, now) != :gt ->
        {:error, :unauthorized}

      code.used_at == nil ->
        {:ok, :outstanding}

      same_public_key?(code.public_key, request.public_key) ->
        enrolled_already(code, node)

      true ->
        {:error, :unauthorized}
    end
  end

  defp same_public_key?(<<_::binary-size(32)>> = stored, encoded) do
    case Ed25519.decode(encoded, 32) do
      {:ok, sent} -> Plug.Crypto.secure_compare(stored, sent)
      :error -> false
    end
  end

  defp same_public_key?(_stored, _encoded), do: false

  # The key checks first, then the proof under the key: either refused is one answer,
  # which the caller sends unsigned. Verification alone accepts a degenerate proof under a
  # key of small order, so the key is checked before the proof is.
  defp proven(request) do
    with {:ok, public_key} <- Ed25519.decode_public_key(request.public_key),
         true <- Enrolment.proof_verifies?(request, public_key) do
      {:ok, public_key}
    else
      _refused -> {:error, :key_unproven}
    end
  end

  # The code's own limit, counted only for a request that came this far: a code accepted,
  # a key proven.
  defp within_code_limit(%EnrolmentCode{id: id}, code_limit) do
    case RateLimit.check({:enrolment_code, id}, code_limit) do
      :ok -> :ok
      {:error, seconds} -> {:error, {:rate_limited, seconds}}
    end
  end

  # The ledger first, then the limit, as the contract orders them: the ledger's entry is
  # undone with the transaction when the limit refuses.
  defp enrol_new(code, node, request, public_key, now, origin) do
    key_id = AccessKey.generate_key_id()

    with :ok <- enrolment_in_ledger(key_id, public_key, now),
         :ok <- within_limit(node) do
      key = %AccessKey{
        id: Ecto.UUID.generate(),
        organisation_id: node.organisation_id,
        workspace_id: node.workspace_id,
        node_id: node.id,
        key_id: key_id,
        public_key: public_key,
        arrived_by: :code,
        enrolment_code_id: code.id,
        received_at: now,
        created_by_id: code.created_by_id
      }

      changeset =
        key
        |> AccessKey.insert_changeset(%{
          allow_secrets: code.allow_secrets,
          label: enrolled_label(node, code.label_hint || request.name)
        })
        |> AccessKey.put_integrity()

      with {:ok, added} <- Repo.insert(changeset),
           {:ok, _used} <-
             code
             |> Ecto.Changeset.change(
               used_at: now,
               used_by_key_id: added.key_id,
               public_key: public_key
             )
             |> EnrolmentCode.put_integrity()
             |> Repo.update(),
           added = %{added | node: node, workspace: node.workspace},
           {:ok, _entry} <-
             Audit.record(
               Repo,
               Scope.put_origin(Scope.for_access_key(added), origin),
               :"access_key.add",
               added,
               %{
                 after: %{
                   label: added.label,
                   key_id: added.key_id,
                   fingerprint: AccessKey.fingerprint(added),
                   allow_secrets: added.allow_secrets,
                   arrived_by: added.arrived_by
                 },
                 details: %{node_id: node.public_id, code_id: code.id}
               }
             ) do
        {:ok, added}
      end
    end
  end

  # A public key in the ledger already, in any state, is refused as an invalid one is.
  defp enrolment_in_ledger(key_id, public_key, now) do
    changeset = Ecto.Changeset.change(%AccessKey{key_id: key_id})

    case enter_in_ledger(changeset, public_key, :current, now) do
      :ok -> :ok
      {:error, %Ecto.Changeset{}} -> {:error, :key_invalid}
    end
  end

  # The label a key enrolled on `node` gets: `base`, or `base-2`, `base-3` and on, the
  # first no key of the node in use has; the node is locked, so no other key takes it.
  defp enrolled_label(%Node{id: node_id}, base) do
    taken =
      Repo.all(
        from k in AccessKey,
          where: k.node_id == ^node_id and is_nil(k.revoked_at),
          select: k.label
      )
      |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  # The key the used code made, while it is in use and intact: the answer again.
  defp enrolled_already(%EnrolmentCode{used_by_key_id: key_id} = code, node) do
    query =
      from k in AccessKey,
        where: k.key_id == ^key_id and k.node_id == ^node.id,
        where: k.enrolment_code_id == ^code.id and is_nil(k.revoked_at)

    with %AccessKey{} = key <- Repo.one(query) || {:error, :unauthorized},
         :ok <- intact(key) do
      {:ok, {:used, %{key | node: node, workspace: node.workspace}}}
    else
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  @doc """
  revoke_node_keys/3 revokes every key of `node` in use, and cancels its outstanding
  enrolment codes, inside the caller's transaction, which holds the node's row
  `FOR UPDATE` and has asked what it does of `Apiary.Access`: the deletion of the node
  (`Apiary.Nodes.delete_node/2`). Each key's public key becomes a tombstone for `reason`,
  and each key leaves an entry of `access_key.revoke`. Returns the key ids revoked, or
  `{:error, changeset}`.
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

  # A key retired, by revocation or its node's deletion: revoked from now on, by the
  # scope's person, its public key a tombstone, and the entry of `action`.
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

  # A key made in a browser or an enrolment is refused while the node holds two keys not
  # revoked.
  defp within_limit(%Node{id: node_id}) do
    held =
      Repo.one(
        from k in AccessKey,
          where: k.node_id == ^node_id and is_nil(k.revoked_at),
          select: count(k.id)
      )

    if held >= @key_limit, do: {:error, :key_limit}, else: :ok
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

  @doc "Records a use: `last_used_at` now, plus `last_forager_version` and `last_contract_version` from `attrs`."
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
        last_forager_version: attrs[:last_forager_version],
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
end

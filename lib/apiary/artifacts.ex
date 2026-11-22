defmodule Apiary.Artifacts do
  # Artifacts stores the results of a work item's runs and people's edits: artifacts by
  # type and name (`Apiary.Artifacts.Artifact`), each with numbered versions
  # (`Apiary.Artifacts.Version`) of one or more files (`Apiary.Artifacts.ArtifactFile`),
  # whose content is in a store (`Apiary.Artifacts.Store`). Every artifact is untrusted
  # data: a page shows it only in the views Qory Apiary ships.
  #
  # ## Types
  #
  # `types(workspace)` is the standard types the workspace shows and the workspace's custom
  # types, and `type(workspace, name)` one of them, nil for a name neither has and for a
  # hidden standard type (`Apiary.Artifacts.Type`). `all_types(workspace)` is the eleven
  # standard types, each with `shown` set, and the custom types, for the settings page.
  #
  # A workspace's `shown_standard_types` is the list of the standard types it shows, nil
  # for all eleven; an always-on type (`Type.always_on/0`) is shown whatever the list
  # contains. `types/1` and `all_types/1` read the list from the database by the
  # workspace's id, and `type/2` reads it the same way for a standard type that can be
  # hidden and for no other name: a caller's struct can have the field unset, or be older
  # than a change of the list. A workspace's `locked_standard_types` is the list of the
  # standard types a run cannot withdraw a name of, which the same three functions read
  # into each type's `withdrawable`.
  #
  # `create_type/3`, `update_type/3` and `delete_type/2` edit a workspace's custom types,
  # the Artifact types section of its settings: each checks `artifact_type.edit` with
  # `Apiary.Access` and writes its entry in the audit trail, about the workspace. A custom
  # type's name and base view are fixed once it is made. A type is deleted only while no
  # artifact of the workspace has its name, else `:in_use`. `insert_template_type/3` makes
  # a custom type for a new workspace (`Apiary.Artifacts.TemplateTypes`), with its entry in
  # the audit trail, and neither checks `artifact_type.edit` nor checks the schema again.
  #
  # `switch_type/4` switches a standard type on or off in a workspace, under the same
  # action: `{:ok, type}`, with `shown` set. An always-on type is `{:error, :always_on}`.
  # A name that is no standard type is `{:error, :not_found}`, as a custom type has no
  # switch. Switching a type to the state it has writes no row and no audit entry.
  # Switching off stops at the first of these, as `{:error, reason}`:
  #
  #   1. `:has_artifacts`: an artifact of the workspace has the type;
  #   2. `:current_process`: a stage of the current process has the type in its inputs
  #      or outputs;
  #   3. `:version_in_use`: a stage of a version in use has the type there. A version is
  #      in use while it is a trial, while a work item that has not ended keeps it, or
  #      while a run of the queue that has not ended is on it (`process_version_id`). So a
  #      work item that ended counts only through such a run: a run handed over goes on
  #      after a close, and a claimed run stays on its version after `Processes.assign/3`
  #      or `Processes.drop_trial/2`. Once its runs end, a work item that ended has none
  #      left, and a take in again places it under the current version
  #      (`Apiary.Stages.take_in/2`).
  #
  # A switch holds the scope's places and the workspace's row as `Apiary.Processes` holds
  # them, `FOR NO KEY UPDATE`, and reads the list and the scope again under that lock. So
  # a switch runs before or after a change of the process and a push of a type that can
  # be hidden, never between their checks and their rows.
  #
  # ## A push
  #
  # `push(actor, work_item, type, files, opts)` stores a new version of the work item's
  # artifact of `type` and `opts[:name]`, `main` unless given, made in the stage
  # `opts[:stage_id]`, with the writer's `opts[:note]` and `opts[:decision]`, the public id
  # of the person's note on the work item that asked for the version (`gd_…` or `es_…`,
  # `Apiary.Stages.Notes`), nil for none. `opts[:expect_stage]`, where given,
  # is the stage the caller read, nil for no stage. `actor` is `{:run, run}`, a run of
  # the queue (`Apiary.Dispatches.DispatchRun`) of that work item; or
  # `{:member_action, scope}`, a member's answer, review comment or reply, which only
  # `Apiary.WorkItems.Moves` passes, for a person who may `work_item.review_comment` the
  # work item for the review comments, and `work_item.answer` for any other type. A
  # member action's push writes its entry in the audit trail under the audit action
  # `artifact.write`, which no role takes (`Apiary.Access`). The questions and the review
  # comments (`member_types/0`) take a person's version only as a member action: Moves
  # writes them from the newest version, with the checks of each member action. A member
  # action's push of any other type is `:forbidden`.
  #
  # `files` is a list of `%{filename: name, content_type: text, path: path}` or
  # `%{filename: name, content_type: text, binary: bytes}`; `content_type` is read by
  # nothing (`Apiary.Artifacts.Format` decides it from the bytes). The checks, in order,
  # each refusal `{:error, {code, detail}}`:
  #
  #   1. the actor: a member action whose person `Apiary.Access.authorize/3` returns an
  #      error for `work_item.review_comment` on the review comments, or for
  #      `work_item.answer` on any other type,
  #      `{:error, :not_found}`, `{:error, :forbidden}` or `{:error, :not_approver}`; a
  #      run of another work item, `{:error, :not_found}`;
  #   2. the type: a name of no type, or of a standard type the workspace hides,
  #      `{:unknown_type, name}`; a name of the wrong form, `{:invalid, :type}`; a type
  #      the actor does not write, as the actor rule says;
  #   3. the options: `{:invalid, :name | :stage_id | :note | :decision}`, the last for a
  #      decision that is not text; the questions and the
  #      review comments take only the name `main`, the one Qory Apiary reads, else
  #      `{:invalid, :name}`; the acceptance criteria take only `main` too, else
  #      `{:invalid, {:criteria_name, name}}`;
  #   4. the files: none, `{:invalid, :no_files}`; more than the type's most,
  #      `{:too_many_files, max_files}`; an entry of the wrong shape, a filename
  #      `Apiary.Artifacts.Filename` refuses, or a filename twice,
  #      `{:invalid, {:file | :filename | :duplicate_filename, index}}`, `index` the
  #      entry's position from 0;
  #   5. each file is staged within what is left of the type's size limit, which bounds
  #      all files of a version together: past it, `{:too_large, size_limit}`, the
  #      source read at most 64 KiB past the limit; a path that cannot be read,
  #      `{:invalid, {:unreadable, index}}`;
  #   6. each staged file passes its base view's format check, else
  #      `{:invalid, {:format | :extension | :unreadable, index}}`, for a file of a
  #      proposal also `{:invalid, {:document_size | :image_type | :svg_format |
  #      :svg_root, index}}` or `{:invalid, {{:svg_content, part}, index}}`, `part` the
  #      part of an SVG refused (`Apiary.Artifacts.Format`), or, for a structured file or
  #      a proposal's `sources.json` that its JSON Schema refuses,
  #      `{:invalid, {:schema, index, %{path: path, error: error}}}`: the JSON pointer of
  #      the first failing value, at most 256 bytes, and the validator's message for it,
  #      at most 300 characters, both with their control characters replaced
  #      (`Apiary.Artifacts.SchemaError`);
  #   7. a version of a video type has an MP4 or WebM file beside its WebVTT captions,
  #      else `{:invalid, :no_video}`; a version of `proposal` has exactly one Markdown
  #      file, else `{:invalid, :one_markdown}`; a run's version of `mockup` with a
  #      `screens.json` is a mockup of pages, which passes the checks of
  #      `Apiary.Artifacts.Mockup`, else `{:invalid, {{:mockup, message}, index}}`,
  #      `index` the file's position or nil for the version, or
  #      `{:invalid, {:schema, index, detail}}` for its `screens.json`. Its files are
  #      `screens.json`, `application/json`, and pages, `text/html; charset=utf-8`; a
  #      file of another name is `{:invalid, {{:mockup, message}, index}}` at check 6.
  #      Every other version of `mockup` is pictures, an image type's.
  #
  # In the transaction, under the work item's lock, a version a run pushes of the
  # questions or the review comments keeps what members wrote in the artifact's newest
  # version, and each decision in a version of the questions matches its question
  # (`Apiary.Explore.Questions.check_run/3`,
  # `Apiary.Explore.ReviewComments.check_run/4`), else
  # `{:invalid, {:kept, 0, reason}}`, with the rule it breaks; a newest version whose file
  # cannot be read is `{:error, :store_unavailable}`. Numbers compare by value there. A
  # version of the verdict, from any writer, has each `answer` point about a question that
  # is open in the newest questions of the work item's current take in, else
  # `{:invalid, {:kept, 0, {:not_open, point, question}}}`, `point` counted from 1: the run
  # pushes its questions first (`verdict_kept/4`). A verdict's `track`, which the format check
  # passed, is a track that the gate of the stage the version is made in offers, in the
  # work item's process version, else
  # `{:invalid, {:track_not_offered, %{stage: name | nil, ids: offered, id: track}}}`.
  # Then a `decision` that is not the id of a person's note on the held work item
  # (`Apiary.Stages.Notes.find/2`) is `{:unknown_decision, decision}`, checked before the
  # integers, so a refused decision leaves no staged copy.
  #
  # Then a version of the questions or the review comments, from any writer, is stored
  # with each number that is an integer in value written as an integer: a file with
  # `4.0`, which the schemas take as an integer, is replaced by `Jason.encode!/1` of the
  # document with `4` (`integers/2`), staged within the type's size limit, else
  # `{:too_large, size_limit}`, checked and kept in its place; a file with none stays as
  # it came. So every reader of these two types finds `4`, never `4.0`. This runs after
  # the check of what members wrote, which pins each number of a run's version to a run
  # number or a version, so the file grows by at most a few bytes; and after the format
  # check of the bytes as they came, each member name once included.
  #
  # The rows are written in one transaction, with the staged files: for a standard type a
  # workspace can hide, the workspace's row locked `FOR SHARE` and its list read again, a
  # hidden type `{:unknown_type, name}`; the work item locked `FOR UPDATE`, read again in
  # the workspace it was in, else `{:error, :not_found}`; for a run, its run of the queue
  # read again, one that ended `{:error, :run_ended}`, one a member cancelled
  # `{:error, :run_cancelled}`; the artifact found or made; the
  # check of what members wrote and the integers, as above; the next number, one more
  # than the highest; the version and its audit entry; then every file is kept in the
  # store, and its row written; then, for a run's version of the submission type in
  # `submit.type` of the run's process version, a `watch` entry in the feed of the
  # adapter of the work item's target collection (`Apiary.Adapters.Feed`), one per
  # version. A work item with no target, or a target that no collection matches
  # (`Apiary.Runs.RunCredentials.work_collection/3`), gets no entry, and the version is
  # stored all the same. A push of a standard type reads nothing for the entry. Where the
  # instance's public address is not one the entry takes (plain http to a host that is
  # not `localhost`, `127.0.0.1` or `[::1]`), the push is `{:error, :public_url}` before
  # any file is kept, with a log line that starts with the fix: set `PUBLIC_URL`. A
  # withdrawal writes no entry. The workspace's lock comes first, as in the core's lock
  # order (`Apiary.WorkItems`). An always-on type takes no lock on the workspace:
  # verdicts are the most frequent pushes, and the stage runner pushes them inside
  # transactions that already hold the work item. The work item's lock makes the
  # transactions of pushes to one work item run one after the other, so the numbers of an
  # artifact are 1, 2, … with no gap. With `opts[:expect_stage]`, a held work item in
  # another stage is `{:error, :stage_changed}`, and no row, audit entry or message is
  # written; without it, the stage is not compared. A refusal, or a failure of the
  # transaction before the files are kept, an exception included, writes no row and drops
  # every staged copy, those `integers/2` made included, so a refused push, and a file
  # `integers/2` replaced, keep no file in the store. A failure of the database after the
  # files were kept, a commit that fails after it kept the first files, or an outer
  # transaction that rolls back, leaves them in the store with no version (`commit_all/1`).
  # A store with no root, or one that cannot write, is `{:error, :store_unavailable}`.
  #
  # Once the push's transaction commits, `{:artifact_pushed, work_item_id, version_id}`,
  # the work item's public id (`wi_…`) and the version's (`av_…`), goes to the work item's
  # artifacts topic (`topic/1`), so its pages show the version. A push called inside an
  # outer transaction sends the message when its transaction ends, before the outer one
  # commits: a page that reads at once may not find the version yet, or find none should
  # the outer transaction roll back.
  #
  # ## A withdrawal
  #
  # `withdraw({:run, run}, work_item, type, opts)` stores a withdrawal: a version of the
  # work item's artifact of `type` and `opts[:name]` with no files and `withdrawn` true,
  # by the run, with `opts[:stage_id]`, `opts[:note]` and `opts[:decision]` as a push takes
  # them, the decision checked last, as a push's is. A name is
  # withdrawn when its newest version, leaving out versions by a run a member cancelled, is
  # a withdrawal (`withdrawn?/1`): the stages and the work item's pages leave it out, and
  # the next version with files lists it again. Only a run withdraws a name; any other
  # actor is `{:error, :not_found}`. The checks of the actor, the type and the options are
  # those of a push, 1 to 3. A type Qory Apiary reads itself, `questions`,
  # `review-comments`, `verdict` or `proposal` (`withdrawable_type/1`), is
  # `{:error, {:withdraw, :type}}`, a type with `withdrawable` false is
  # `{:error, {:withdraw, :type_off}}`, and the type in `submit.type` of the run's process
  # version or of the work item's is `{:error, {:withdraw, :submit_type}}`
  # (`withdrawable_type/3`). Then, in the
  # transaction, with the locks and the
  # reads of a push's transaction, the artifact's newest version, leaving out versions by a
  # run a member cancelled, is read, and the withdrawal is refused, as
  # `{:error, {:withdraw, reason}}`, when it is:
  #
  #   - approved by a person: `{:approved, number}`, when a decision of the work item at a
  #     gate, of kind `:approve` and not `automatic`, covers the version (`versions` has its
  #     public id; a member whose account is gone has no `user_id`, and counts) and counts
  #     (`Apiary.Stages.Withdrawals`): with only an approval of an earlier take in, or one
  #     a later move back withdrew, the withdrawal goes ahead. The check comes before the
  #     two below;
  #   - none, as the name has no version outside cancelled runs: `:no_version`;
  #   - a withdrawal: `{:withdrawn, number}`.
  #
  # The version is numbered as a push's, and the same message goes to the work item's
  # artifacts topic.
  #
  # ## Reading
  #
  # `list(work_item)` is the work item's artifacts by type and name, each with its
  # versions, newest first, and their files by filename; `versions(artifact)` an
  # artifact's versions, newest first, with their files; `newest(work_item, type, name)`
  # the version with the highest number, or nil; `get_version!(id)` a version by its
  # public id (`av_…`), with its artifact and files; `open_file(file)` a file's stored
  # copy, a path or a stream of its bytes. Each version comes with its `user`, the
  # person who made it, and its `run`, the run of the queue that made it, where the row
  # is there; that run comes with its `run`, the run its claim registered
  # (`Apiary.Runs.Run`, with its id, public id and `dispatch_run_id` only), or nil before
  # a claim. These read no scope: the caller has read the work item through
  # `Apiary.Access`.
  #
  # `exists?(work_item, stage_id, type)` is the Exists check of a stage's output: whether
  # the work item has a version of `type`, of any name, made in `stage_id`, whose files
  # are what the type takes, by the content types the format check kept at the push
  # (`Apiary.Artifacts.Format.stored?/2`); no file is read again. A version of a name
  # whose newest version is a withdrawal does not count. False for a type the workspace
  # does not have and for a hidden standard type.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, PublicId, Repo, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Feed
  alias Apiary.Artifacts.{Artifact, ArtifactFile, CustomSchema, Filename, Format, Mockup, Store}
  alias Apiary.Artifacts.Type
  alias Apiary.Artifacts.Version
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Explore.{Questions, ReviewComments}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Processes
  alias Apiary.Processes.Version, as: ProcessVersion
  alias Apiary.Runs.RunCredentials
  alias Apiary.Stages.{GateDecision, Withdrawals}
  alias Apiary.WorkItems.{State, WorkItem}

  require Logger

  # The actions of artifacts, of the feature `workflow_model` (`Apiary.Access`):
  # `artifact.write` is the audit action of a member action's version, which no role
  # takes; where the feature is off or hidden from the person, `authorize/3` returns
  # `{:error, :not_found}` for `artifact_type.edit`.
  @write :"artifact.write"
  @edit_types :"artifact_type.edit"

  @stage_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @max_note 4000
  @refused_in_note ~r/(?![\x{9}\x{A}\x{200C}\x{200D}])[\p{Cc}\p{Cf}\x{2028}\x{2029}]/u

  # The types only the member actions write for a person (`Apiary.WorkItems.Moves`).
  @member_types ~w(questions review-comments)

  # The types Qory Apiary reads itself, which a run cannot withdraw (`withdraw/4`).
  @not_withdrawable ~w(questions review-comments verdict proposal)

  @typedoc "Who pushes a version: a run of the queue or a member action."
  @type actor :: {:run, DispatchRun.t()} | {:member_action, Scope.t()}

  @typedoc "A file of a push."
  @type file ::
          %{
            required(:filename) => String.t(),
            optional(:content_type) => String.t(),
            optional(:path) => Path.t(),
            optional(:binary) => binary
          }

  @typedoc "Why a standard type stays in the state it has."
  @type switch_refusal ::
          :always_on | :has_artifacts | :current_process | :version_in_use

  @typedoc "Why a push is refused."
  @type refusal ::
          {:unknown_type | :too_many_files | :too_large | :invalid | :unknown_decision, term}

  ## Types

  @doc false
  @spec types(Workspace.t()) :: [Type.t()]
  def types(%Workspace{id: workspace_id}) do
    {shown, locked} = standard_state(workspace_id)

    shown_types =
      for type <- Type.standard(), shown?(type.name, shown), do: with_lock(type, locked)

    shown_types ++ custom_types(workspace_id)
  end

  # member_types/0 is the names of the types a person writes only through a member
  # action (`Apiary.WorkItems.Moves`), never by a push of their files.
  @doc false
  @spec member_types() :: [String.t()]
  def member_types, do: @member_types

  # submit_types/1 is the names of the types that the process of `workspace` sets as the
  # result of a run (`submit.type` of the harness record, `Processes.harness_template/1`):
  # those of its current version and of each version in use (`switch_type/4`). The harness
  # sets their schemas: no one edits or deletes them.
  @doc false
  @spec submit_types(Workspace.t()) :: [String.t()]
  def submit_types(%Workspace{id: workspace_id}) do
    current =
      from v in ProcessVersion, where: v.workspace_id == ^workspace_id and v.status == :current

    in_use = versions_in_use(workspace_id)

    (Repo.all(from v in current, select: v.id) ++ Repo.all(from v in in_use, select: v.id))
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case Processes.harness_template(id) do
        %{"submit" => %{"type" => type}} when is_binary(type) -> [type]
        _none -> []
      end
    end)
    |> Enum.uniq()
  end

  @doc false
  @spec all_types(Workspace.t()) :: [Type.t()]
  def all_types(%Workspace{id: workspace_id}) do
    {shown, locked} = standard_state(workspace_id)

    Enum.map(Type.standard(), &%{with_lock(&1, locked) | shown: shown?(&1.name, shown)}) ++
      custom_types(workspace_id)
  end

  @doc false
  @spec type(Workspace.t(), term) :: Type.t() | nil
  def type(%Workspace{id: workspace_id}, name) when is_binary(name) do
    case Enum.find(Type.standard(), &(&1.name == name)) do
      %Type{} = standard ->
        # An always-on type reads no list: a run cannot withdraw it by name anyway.
        if name in Type.always_on() do
          standard
        else
          {shown, locked} = standard_state(workspace_id)
          if shown?(name, shown), do: with_lock(standard, locked)
        end

      nil ->
        if Type.name?(name),
          do: Repo.one(from t in Type, where: t.workspace_id == ^workspace_id and t.name == ^name)
    end
  end

  def type(%Workspace{}, _name), do: nil

  defp custom_types(workspace_id),
    do: Repo.all(from t in Type, where: t.workspace_id == ^workspace_id, order_by: t.name)

  # The workspace's `shown_standard_types` and `locked_standard_types`; nil and no names for
  # a workspace that is gone.
  defp standard_state(workspace_id) do
    Repo.one(
      from w in Workspace,
        where: w.id == ^workspace_id,
        select: {w.shown_standard_types, w.locked_standard_types}
    ) || {nil, []}
  end

  # The standard type `type` with `withdrawable` false where the workspace locks it.
  defp with_lock(%Type{name: name} = type, locked), do: %{type | withdrawable: name not in locked}

  defp shown?(_name, nil), do: true
  defp shown?(name, shown), do: name in Type.always_on() or name in shown

  # create_type/3 makes a custom type in `workspace`: `{:ok, type}`,
  # `{:error, :not_found | :forbidden}`, or `{:error, changeset}`. `attrs` has `name`,
  # `base_view`, `size_limit`, `max_files` and, for a structured type, `json_schema`, a
  # map or its JSON text. A `withdrawable` in `attrs` is left out: only a template's
  # `artifact_types` entry sets it (`insert_template_type/3`).
  @doc false
  @spec create_type(Scope.t(), Workspace.t(), map) ::
          {:ok, Type.t()} | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  def create_type(%Scope{} = scope, %Workspace{} = workspace, attrs) do
    Repo.transact(fn ->
      with :ok <- authorize(scope, @edit_types, workspace),
           {:ok, changeset} <-
             %Type{organisation_id: workspace.organisation_id, workspace_id: workspace.id}
             |> Type.create_changeset(
               attrs
               |> json_attrs()
               |> Map.drop([:withdrawable, "withdrawable"])
             )
             |> checked_schema(),
           {:ok, type} <- PublicId.Insert.insert(changeset),
           {:ok, _entry} <- audit_type(scope, workspace, :create, type) do
        {:ok, type}
      end
    end)
  end

  # insert_template_type/3 makes a custom type of a template's checked definition in a new
  # workspace, inside the caller's transaction: `{:ok, type}` or `{:error, changeset}`.
  @doc false
  @spec insert_template_type(Scope.t(), Workspace.t(), map) ::
          {:ok, Type.t()} | {:error, Ecto.Changeset.t()}
  def insert_template_type(%Scope{} = scope, %Workspace{} = workspace, definition) do
    changeset =
      Type.create_changeset(
        %Type{organisation_id: workspace.organisation_id, workspace_id: workspace.id},
        definition
      )

    with {:ok, type} <- PublicId.Insert.insert(changeset),
         {:ok, _entry} <- audit_type(scope, workspace, :create, type) do
      {:ok, type}
    end
  end

  # update_type/3 changes a custom type's size limit, most files and JSON Schema. It and
  # delete_type/2 hold the scope's places, the workspace `FOR NO KEY UPDATE` and the type's
  # row, in that order, so a change of the process that makes the type one that its
  # `submit` sets (`submit_types/1`) takes turns with them.
  @doc false
  @spec update_type(Scope.t(), Type.t(), map) ::
          {:ok, Type.t()}
          | {:error, :not_found | :forbidden | :set_by_harness | Ecto.Changeset.t()}
  def update_type(%Scope{} = scope, %Type{standard: false} = type, attrs) do
    Repo.transact(fn ->
      with {:ok, scope, _workspace} <- held_workspace(scope, %Workspace{id: type.workspace_id}),
           :ok <- authorize(scope, @edit_types, type),
           %Type{} = held <- held_type(type),
           :ok <- not_set_by_harness(held),
           {:ok, changeset} <-
             held |> Type.update_changeset(json_attrs(attrs)) |> checked_schema(),
           {:ok, updated} <- Repo.update(changeset),
           {:ok, _entry} <- audit_type(scope, workspace_of(held), :update, updated) do
        {:ok, updated}
      else
        nil -> {:error, :not_found}
        {:error, _refusal} = refused -> refused
      end
    end)
  end

  def update_type(%Scope{}, %Type{}, _attrs), do: {:error, :not_found}

  # delete_type/2 deletes a custom type no artifact of its workspace has: `{:ok, type}`,
  # `{:error, :in_use}`, or `{:error, :not_found | :forbidden}`.
  @doc false
  @spec delete_type(Scope.t(), Type.t()) ::
          {:ok, Type.t()} | {:error, :not_found | :forbidden | :in_use | :set_by_harness}
  def delete_type(%Scope{} = scope, %Type{standard: false} = type) do
    Repo.transact(fn ->
      with {:ok, scope, _workspace} <- held_workspace(scope, %Workspace{id: type.workspace_id}),
           :ok <- authorize(scope, @edit_types, type),
           %Type{} = held <- held_type(type),
           :ok <- not_set_by_harness(held),
           false <- in_use?(held.workspace_id, held.name),
           {:ok, deleted} <- Repo.delete(held),
           {:ok, _entry} <- audit_type(scope, workspace_of(held), :delete, held) do
        {:ok, deleted}
      else
        nil -> {:error, :not_found}
        true -> {:error, :in_use}
        {:error, _refusal} = refused -> refused
      end
    end)
  end

  def delete_type(%Scope{}, %Type{}), do: {:error, :not_found}

  # switch_type/4 switches the standard type `name` on or off in `workspace`: see Types
  # at the head of this module.
  @doc false
  @spec switch_type(Scope.t(), Workspace.t(), term, boolean) ::
          {:ok, Type.t()} | {:error, switch_refusal | Access.reason()}
  def switch_type(%Scope{} = scope, %Workspace{} = workspace, name, on?) when is_boolean(on?) do
    Repo.transact(fn ->
      with {:ok, scope, held} <- held_workspace(scope, workspace),
           :ok <- Access.check(scope, @edit_types, held),
           {:ok, type} <- switchable(name) do
        if shown?(name, held.shown_standard_types) == on?,
          do: {:ok, %{type | shown: on?}},
          else: switch(scope, held, type, on?)
      end
    end)
  end

  @doc false
  # show_template_types/3 shows the standard types `names` in `workspace` too, for a save
  # of its harness's template (Apiary.Processes.HarnessUpdate), inside the caller's
  # transaction, in which the caller has locked the workspace: `shown_standard_types` in
  # the order of `Type.standard_names/0`, and an audit entry `show` for each type it
  # shows, as `switch_type/4` writes one. `:ok`.
  @spec show_template_types(Scope.t(), Workspace.t(), [String.t()]) :: :ok
  def show_template_types(%Scope{}, %Workspace{}, []), do: :ok

  def show_template_types(%Scope{} = scope, %Workspace{} = workspace, names) do
    held = Repo.get!(Workspace, workspace.id)
    hideable = Type.standard_names() -- Type.always_on()
    added = Enum.filter(hideable, &(&1 in names and not shown?(&1, held.shown_standard_types)))

    if added != [] do
      shown = Enum.filter(hideable, &(&1 in added or shown?(&1, held.shown_standard_types)))

      {1, _rows} =
        Repo.update_all(from(w in Workspace, where: w.id == ^held.id),
          set: [shown_standard_types: shown, updated_at: DateTime.utc_now()]
        )

      for name <- added do
        type = Enum.find(Type.standard(), &(&1.name == name))
        {:ok, _entry} = audit_type(scope, held, :show, type)
      end
    end

    :ok
  end

  # The scope's places and the workspace held, the workspace `FOR NO KEY UPDATE`, and the
  # scope read again, in the order of `Apiary.Processes`: `{:ok, scope, workspace}`, or
  # `{:error, :not_found}` for a workspace other than the scope's.
  defp held_workspace(%Scope{} = scope, %Workspace{id: id}) do
    :ok = Access.lock_places(scope)

    with %Workspace{id: ^id} <- scope.workspace,
         %Workspace{} = workspace <-
           Repo.one(
             from w in Workspace,
               where: w.id == ^id and w.organisation_id == ^scope.organisation.id,
               lock: "FOR NO KEY UPDATE"
           ) do
      {:ok, Access.reload(scope, lock: :share), workspace}
    else
      _other -> {:error, :not_found}
    end
  end

  defp switchable(name) do
    cond do
      name in Type.always_on() -> {:error, :always_on}
      type = Enum.find(Type.standard(), &(&1.name == name)) -> {:ok, type}
      true -> {:error, :not_found}
    end
  end

  defp switch(scope, workspace, %Type{name: name} = type, on?) do
    with :ok <- if(on?, do: :ok, else: not_in_use(workspace, name)),
         {:ok, _workspace} <-
           workspace
           |> Ecto.Changeset.change(
             shown_standard_types: switched(workspace.shown_standard_types, name, on?)
           )
           |> Repo.update(),
         {:ok, _entry} <- audit_type(scope, workspace, if(on?, do: :show, else: :hide), type) do
      {:ok, %{type | shown: on?}}
    end
  end

  # The list after a switch: the names that can be hidden and stay shown, in the order of
  # `Type.standard/0`.
  defp switched(shown, name, on?) do
    Enum.filter(Type.standard_names() -- Type.always_on(), fn candidate ->
      if candidate == name, do: on?, else: shown?(candidate, shown)
    end)
  end

  defp not_in_use(%Workspace{id: workspace_id} = workspace, name) do
    cond do
      in_use?(workspace_id, name) -> {:error, :has_artifacts}
      has_type?(Processes.current(workspace).document, name) -> {:error, :current_process}
      Enum.any?(documents_in_use(workspace_id), &has_type?(&1, name)) -> {:error, :version_in_use}
      true -> :ok
    end
  end

  # The documents of the workspace's trial versions, of the versions that its work items
  # that have not ended keep, and of the versions that its runs of the queue that have not
  # ended are on. An ended work item's version counts only through such a run.
  defp documents_in_use(workspace_id),
    do: Repo.all(from v in versions_in_use(workspace_id), select: v.document)

  defp versions_in_use(workspace_id) do
    kept =
      from w in WorkItem,
        where:
          w.workspace_id == ^workspace_id and w.state not in ^State.ended_states() and
            not is_nil(w.process_version_id),
        select: w.process_version_id

    running =
      from r in DispatchRun,
        where:
          r.workspace_id == ^workspace_id and r.state != :ended and
            not is_nil(r.process_version_id),
        select: r.process_version_id

    from v in ProcessVersion,
      where:
        v.workspace_id == ^workspace_id and
          (v.status == :trial or v.id in subquery(kept) or v.id in subquery(running))
  end

  # Whether a stage of `document` has the type among its inputs or outputs, the entries
  # `Apiary.Processes.placement_check/3` reads.
  defp has_type?(document, name) do
    document
    |> Map.get("stages", [])
    |> Enum.any?(fn stage ->
      entries = Map.get(stage, "inputs", []) ++ Map.get(stage, "outputs", [])
      Enum.any?(entries, &(&1["type"] == name))
    end)
  end

  # The type's row, locked `FOR UPDATE` until the change commits; nil once it is gone.
  defp held_type(%Type{id: id, workspace_id: workspace_id}) do
    Repo.one(
      from t in Type,
        where: t.id == ^id and t.workspace_id == ^workspace_id,
        lock: "FOR UPDATE"
    )
  end

  # `{:error, :set_by_harness}` for a type that `submit_types/1` lists.
  defp not_set_by_harness(%Type{name: name, workspace_id: workspace_id}) do
    if name in submit_types(%Workspace{id: workspace_id}),
      do: {:error, :set_by_harness},
      else: :ok
  end

  defp in_use?(workspace_id, name) do
    Repo.exists?(from a in Artifact, where: a.workspace_id == ^workspace_id and a.type == ^name)
  end

  defp workspace_of(%Type{workspace_id: workspace_id}), do: Repo.get!(Workspace, workspace_id)

  # A form sends the schema as JSON text: decoded here, so the changeset casts a map. A
  # text of more than 262,144 bytes, four times the most a schema has as canonical JSON
  # (`Apiary.Artifacts.CustomSchema`), is not decoded, and the cast refuses it.
  defp json_attrs(attrs) do
    attrs = Map.new(attrs)

    Enum.reduce([:json_schema, "json_schema"], attrs, fn key, attrs ->
      case attrs do
        %{^key => text} when is_binary(text) and byte_size(text) <= 262_144 ->
          case Jason.decode(text) do
            {:ok, decoded} -> Map.put(attrs, key, decoded)
            {:error, _reason} -> Map.put(attrs, key, text)
          end

        _other ->
          attrs
      end
    end)
  end

  defp checked_schema(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp checked_schema(changeset) do
    case Ecto.Changeset.fetch_change(changeset, :json_schema) do
      {:ok, schema} when is_map(schema) ->
        case CustomSchema.check(schema) do
          :ok ->
            {:ok, changeset}

          {:error, refusal} ->
            {:error,
             Ecto.Changeset.add_error(
               changeset,
               :json_schema,
               "is not a schema Qory Apiary takes",
               validation: refusal
             )}
        end

      _none ->
        {:ok, changeset}
    end
  end

  defp audit_type(scope, workspace, change, %Type{} = type) do
    Audit.record(Repo, scope, @edit_types, workspace, %{
      details: %{"change" => Atom.to_string(change), "type" => type.name}
    })
  end

  ## A push

  @doc false
  @spec push(actor, WorkItem.t(), term, [file], keyword) ::
          {:ok, Version.t()}
          | {:error,
             refusal
             | :not_found
             | :forbidden
             | :not_approver
             | :store_unavailable
             | :stage_changed
             | :run_ended
             | :run_cancelled
             | :public_url}
  def push(actor, %WorkItem{} = work_item, type_name, files, opts \\ []) do
    with {:ok, work_item} <- current(work_item),
         {:ok, writer} <- writer(actor, work_item, type_name),
         {:ok, type} <- push_type(work_item, type_name),
         :ok <- actor_type(writer, type),
         {:ok, fields} <- fields(opts),
         :ok <- member_name(type, fields),
         :ok <- criteria_name(type, fields),
         {:ok, files} <- files(type, files),
         checked = checked_type(writer, type, files),
         {:ok, staged} <- stage_all(checked, files),
         :ok <- complete(checked, staged) do
      writer |> write(work_item, type, fields, staged) |> broadcast()
    end
  end

  @doc false
  @spec withdraw(actor, WorkItem.t(), term, keyword) ::
          {:ok, Version.t()}
          | {:error,
             refusal
             | {:withdraw,
                :type
                | :type_off
                | :submit_type
                | {:approved, pos_integer}
                | :no_version
                | {:withdrawn, pos_integer}}
             | :not_found
             | :stage_changed
             | :run_ended
             | :run_cancelled}
  def withdraw(actor, work_item, type_name, opts \\ [])

  def withdraw(
        {:run, %DispatchRun{} = dispatch_run} = actor,
        %WorkItem{} = work_item,
        type_name,
        opts
      ) do
    with {:ok, work_item} <- current(work_item),
         {:ok, writer} <- writer(actor, work_item, type_name),
         {:ok, type} <- push_type(work_item, type_name),
         :ok <- actor_type(writer, type),
         :ok <- withdrawable_type(type, dispatch_run, work_item),
         {:ok, fields} <- fields(opts),
         :ok <- member_name(type, fields) do
      writer |> write_withdrawal(work_item, type, fields) |> broadcast()
    end
  end

  def withdraw(_actor, _work_item, _type_name, _opts), do: {:error, :not_found}

  # withdrawable_type/1 is `:ok` when a run may withdraw a name of `type`: every type but
  # those Qory Apiary reads itself, `questions`, `review-comments`, `verdict` and
  # `proposal`, and those a template sets `withdrawable: false`. A withdrawal of one of
  # the first would leave the stage runner or Explore with a newest version that has no
  # file to read. Else `{:error, {:withdraw, :type}}` for the first, and
  # `{:error, {:withdraw, :type_off}}` for the second.
  @doc false
  @spec withdrawable_type(Type.t()) :: :ok | {:error, {:withdraw, :type | :type_off}}
  def withdrawable_type(%Type{name: name}) when name in @not_withdrawable,
    do: {:error, {:withdraw, :type}}

  def withdrawable_type(%Type{withdrawable: false}), do: {:error, {:withdraw, :type_off}}
  def withdrawable_type(%Type{}), do: :ok

  # withdrawable_type/2 is `withdrawable_type/1`, and `{:error, {:withdraw, :submit_type}}`
  # for the type in `submit.type` of the run's process version and for the one in
  # `submit.type` of the work item's process version, which the Submissions list reads
  # (`Apiary.Submissions`): Qory Apiary reads the newest version of that type as the run's
  # submission, so a withdrawal would leave it with none. Versions stored earlier stay.
  @doc false
  @spec withdrawable_type(Type.t(), DispatchRun.t(), WorkItem.t()) ::
          :ok | {:error, {:withdraw, :type | :type_off | :submit_type}}
  def withdrawable_type(%Type{name: name} = type, %DispatchRun{} = dispatch_run, work_item) do
    with :ok <- withdrawable_type(type) do
      if name in [submit_type(dispatch_run), submit_type(work_item)],
        do: {:error, {:withdraw, :submit_type}},
        else: :ok
    end
  end

  # The withdrawal's row, under the locks and reads of a push's transaction (`write/5`),
  # when the artifact's newest version has files (`withdrawable/3`).
  defp write_withdrawal(writer, work_item, type, fields) do
    Repo.transact(fn ->
      now = DateTime.utc_now()

      with :ok <- shown_kept(work_item, type),
           %WorkItem{} = held <- held_work_item(work_item),
           :ok <- run_live(writer),
           :ok <- stage_kept(held, fields.expect_stage),
           :ok <- type_kept(type),
           {:ok, artifact} <- withdrawable(held, type, fields),
           :ok <- decision_kept(held, fields.decision),
           {:ok, version} <- version(artifact, writer, Map.put(fields, :withdrawn, true), now) do
        {:ok, {Repo.preload(%{version | artifact: artifact}, files: files_query()), held}}
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  # The artifact of the held work item, `type` and the name, when its newest version that
  # no cancelled run wrote (`withdrawn?/1`) has files.
  defp withdrawable(held, type, fields) do
    newest =
      Repo.one(
        from v in Version,
          as: :version,
          join: a in assoc(v, :artifact),
          where: a.work_item_id == ^held.id and a.type == ^type.name and a.name == ^fields.name,
          where: not exists(Apiary.Runs.Run.cancelled_dispatch_run(:version, :run_id)),
          order_by: [desc: v.number],
          limit: 1,
          preload: [artifact: a]
      )

    case newest do
      nil ->
        {:error, {:withdraw, :no_version}}

      %Version{} = version ->
        if person_approved?(held, version),
          do: {:error, {:withdraw, {:approved, version.number}}},
          else: with_files(version)
    end
  end

  defp with_files(%Version{withdrawn: true, number: number}),
    do: {:error, {:withdraw, {:withdrawn, number}}}

  defp with_files(%Version{artifact: artifact}), do: {:ok, artifact}

  # Whether a person approved `version` at a gate of the work item: a decision of kind
  # `:approve` that is not `automatic`, covers the version's public id and counts: made in
  # the work item's take in and withdrawn by no later move (`Apiary.Stages.Withdrawals`).
  # A nil `user_id` is a member whose account is gone (`Apiary.Stages.GateDecision`), and
  # counts.
  defp person_approved?(held, %Version{public_id: public_id}) do
    from(d in GateDecision,
      as: :decision,
      where: d.work_item_id == ^held.id and d.kind == :approve and d.automatic == false,
      where: fragment("? @> to_jsonb(?::text)", d.versions, ^public_id)
    )
    |> Withdrawals.counted(held)
    |> Repo.exists?()
  end

  # The shape of a refusal for the server log, with nothing of a file, a filename or a
  # note: a text is `"…"`, a list `[…]` (a charlist is text too), a changeset its schema
  # and the fields with errors, and an exception its module.
  defp shape(%Ecto.Changeset{data: %schema{}, errors: errors}) do
    fields = errors |> Keyword.keys() |> Enum.uniq() |> Enum.map_join(", ", &Atom.to_string/1)
    "changeset of #{inspect(schema)}, errors on #{fields}"
  end

  defp shape(%{__exception__: true, __struct__: module}), do: inspect(module)
  defp shape(%{__struct__: module}), do: "%#{inspect(module)}{…}"
  defp shape(value) when is_atom(value) or is_number(value), do: inspect(value)
  defp shape(value) when is_binary(value), do: ~s("…")

  defp shape(value) when is_tuple(value),
    do: "{" <> (value |> Tuple.to_list() |> Enum.map_join(", ", &shape/1)) <> "}"

  defp shape(value) when is_list(value), do: "[…]"

  defp shape(value) when is_map(value), do: "%{…}"
  defp shape(_value), do: "…"

  # topic/1 is the PubSub topic of the work item's artifacts (`"artifacts:<work item
  # id>"`, its internal id): after each push, `{:artifact_pushed, work_item_id,
  # version_id}`, with the work item's public id (`wi_…`) and the version's (`av_…`). One
  # topic per work item, so that only its pages get the message.
  @doc false
  @spec topic(WorkItem.t()) :: String.t()
  def topic(%WorkItem{id: id}) when is_binary(id), do: "artifacts:" <> id

  # subscribe/2 subscribes the caller to the work item's artifacts topic (`topic/1`), for
  # a person who may read the work item (`work_item.read`): `:ok`, or `Apiary.Access`'s
  # refusal.
  @doc false
  @spec subscribe(Scope.t(), WorkItem.t()) :: :ok | {:error, Access.reason()}
  def subscribe(%Scope{} = scope, %WorkItem{} = work_item) do
    with :ok <- Access.authorize(scope, :"work_item.read", work_item),
         do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(work_item))
  end

  # After the push's transaction ends, the work item's pages hear of the new version
  # (`topic/1`), with the work item's public id as the transaction read it.
  defp broadcast({:ok, {%Version{} = version, %WorkItem{} = held}}) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      topic(held),
      {:artifact_pushed, held.public_id, version.public_id}
    )

    {:ok, version}
  end

  defp broadcast(refused), do: refused

  # The work item as it is now, unlocked: the transaction reads it again under its lock.
  defp current(%WorkItem{id: id}) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        case Repo.get(WorkItem, id) do
          %WorkItem{} = found -> {:ok, found}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  # A member action: Moves checked the member's action, under the work item's lock, before
  # it pushes; `artifact.write` is only the audit action of its entry. The action asked is
  # the one of the type: the review comments' for them, the answer's for the questions and
  # any other type, for which `actor_type/2` returns `{:error, :forbidden}`.
  defp writer({:member_action, %Scope{user: %{id: user_id}} = scope}, work_item, type_name)
       when is_binary(user_id) do
    with :ok <- authorize(scope, member_action(type_name), work_item),
         do:
           {:ok,
            %{
              actor: :member_action,
              writer: :person,
              user_id: user_id,
              run_id: nil,
              scope: scope
            }}
  end

  defp writer({:run, %DispatchRun{id: run_id} = run}, %WorkItem{} = work_item, _type_name)
       when is_binary(run_id) do
    if run.work_item_id == work_item.id and run.organisation_id == work_item.organisation_id,
      do: {:ok, %{actor: :run, writer: :run, user_id: nil, run_id: run_id, scope: nil, run: run}},
      else: {:error, :not_found}
  end

  defp writer(_actor, _work_item, _type_name), do: {:error, :not_found}

  defp member_action("review-comments"), do: :"work_item.review_comment"
  defp member_action(_type_name), do: :"work_item.answer"

  # The types each actor writes: a member action only the member types, a run any.
  defp actor_type(%{actor: :member_action}, %Type{name: name}) when name in @member_types,
    do: :ok

  defp actor_type(%{actor: :member_action}, %Type{}), do: {:error, :forbidden}
  defp actor_type(_writer, %Type{}), do: :ok

  # The one call site of `Apiary.Access.authorize/3` for this module's actions.
  defp authorize(scope, action, subject), do: Access.authorize(scope, action, subject)

  defp push_type(work_item, name) do
    workspace = %Workspace{id: work_item.workspace_id, organisation_id: work_item.organisation_id}

    cond do
      not Type.name?(name) -> {:error, {:invalid, :type}}
      type = type(workspace, name) -> {:ok, type}
      true -> {:error, {:unknown_type, name}}
    end
  end

  defp fields(opts) do
    name = Keyword.get(opts, :name, "main")
    stage_id = Keyword.get(opts, :stage_id)
    note = normal_note(Keyword.get(opts, :note))
    decision = Keyword.get(opts, :decision)
    expect_stage = Keyword.fetch(opts, :expect_stage)

    cond do
      not Type.name?(name) ->
        {:error, {:invalid, :name}}

      not stage_id?(stage_id) ->
        {:error, {:invalid, :stage_id}}

      not note?(note) ->
        {:error, {:invalid, :note}}

      not (is_nil(decision) or is_binary(decision)) ->
        {:error, {:invalid, :decision}}

      true ->
        {:ok,
         %{
           name: name,
           stage_id: stage_id,
           note: note,
           decision: decision,
           expect_stage: expect_stage
         }}
    end
  end

  # A version's `decision` is the public id of a person's note on the held work item
  # (`Apiary.Stages.Notes`), or nil. A note is never deleted, so the check stays true once
  # the version is stored.
  defp decision_kept(_held, nil), do: :ok

  defp decision_kept(held, decision) do
    case Apiary.Stages.Notes.find(held.id, decision) do
      %{id: ^decision} -> :ok
      nil -> {:error, {:unknown_decision, decision}}
    end
  end

  # The questions and the review comments are one document per work item, named `main`:
  # a version under another name would go unchecked and unread.
  defp member_name(%Type{name: type}, %{name: name}) when type in @member_types,
    do: if(name == "main", do: :ok, else: {:error, {:invalid, :name}})

  defp member_name(%Type{}, _fields), do: :ok

  # A work item has one set of acceptance criteria, under the name `main`: the work
  # item's page shows that name alone as its criteria, so a push under another name
  # fails.
  defp criteria_name(%Type{name: "acceptance-criteria"}, %{name: name}) when name != "main",
    do: {:error, {:invalid, {:criteria_name, name}}}

  defp criteria_name(%Type{}, _fields), do: :ok

  defp stage_id?(nil), do: true
  defp stage_id?(id) when is_binary(id), do: Regex.match?(@stage_id, id)
  defp stage_id?(_id), do: false

  # A note's line breaks become line feeds and it is trimmed; empty, it is none.
  defp normal_note(note) when is_binary(note) do
    if String.valid?(note) do
      case note |> String.replace(["\r\n", "\r"], "\n") |> String.trim() do
        "" -> nil
        text -> text
      end
    else
      note
    end
  end

  defp normal_note(note), do: note

  defp note?(nil), do: true

  # The length is counted in code points, as the database's `char_length` counts it
  # (`artifact_versions_note_check`): "é" written as "e" and U+0301 is one grapheme and
  # two code points.
  defp note?(note) when is_binary(note) do
    byte_size(note) <= 4 * @max_note and String.valid?(note) and
      length(String.to_charlist(note)) <= @max_note and
      not Regex.match?(@refused_in_note, note)
  end

  defp note?(_note), do: false

  defp files(_type, []), do: {:error, {:invalid, :no_files}}

  defp files(%Type{max_files: max}, files) when is_list(files) do
    if length(files) > max do
      {:error, {:too_many_files, max}}
    else
      files
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {file, index}, {:ok, acc, seen} ->
        case source(file) do
          {:ok, filename, source} ->
            cond do
              not Filename.valid?(filename) ->
                {:halt, {:error, {:invalid, {:filename, index}}}}

              MapSet.member?(seen, filename) ->
                {:halt, {:error, {:invalid, {:duplicate_filename, index}}}}

              true ->
                {:cont, {:ok, [{index, filename, source} | acc], MapSet.put(seen, filename)}}
            end

          :error ->
            {:halt, {:error, {:invalid, {:file, index}}}}
        end
      end)
      |> case do
        {:ok, files, _seen} -> {:ok, Enum.reverse(files)}
        {:error, _refusal} = refused -> refused
      end
    end
  end

  defp files(_type, _files), do: {:error, {:invalid, :no_files}}

  defp source(%{filename: filename, path: path}) when is_binary(path),
    do: {:ok, filename, {:path, path}}

  defp source(%{filename: filename, binary: binary}) when is_binary(binary),
    do: {:ok, filename, {:binary, binary}}

  defp source(_file), do: :error

  # Each file staged within what is left of the size limit, then checked; on a refusal,
  # every staged copy is dropped.
  defp stage_all(%Type{size_limit: limit} = type, files) do
    store = Store.impl()

    files
    |> Enum.reduce_while({:ok, [], 0}, fn {index, filename, source}, {:ok, acc, used} ->
      case stage_one(store, type, index, filename, source, limit - used) do
        {:ok, staged} -> {:cont, {:ok, [staged | acc], used + staged.size}}
        {:error, refusal} -> {:halt, {:error, refusal, acc}}
      end
    end)
    |> case do
      {:ok, staged, _used} ->
        {:ok, Enum.reverse(staged)}

      {:error, refusal, staged} ->
        Enum.each(staged, &store.discard(&1.staged))
        {:error, refusal}
    end
  end

  # The type a version's files are checked as: a run's version of `mockup` with a
  # `screens.json` as a mockup of pages, the base view `:mockup`; any other version as
  # its type.
  defp checked_type(%{actor: :run}, %Type{standard: true, name: "mockup"} = type, files) do
    if Enum.any?(files, fn {_index, filename, _source} -> filename == Mockup.index_name() end),
      do: %Type{type | base_view: :mockup},
      else: type
  end

  # A run's version of its submit type is checked against the schema in the harness commit
  # the run composes where `Processes.submit_schema/2` finds it, else against the
  # workspace's type.
  defp checked_type(
         %{actor: :run, run: %DispatchRun{} = run},
         %Type{standard: false, base_view: :structured} = type,
         _files
       ) do
    case Processes.submit_schema(run, type.name) do
      {:ok, schema} -> %Type{type | json_schema: schema}
      :none -> type
    end
  end

  defp checked_type(_writer, type, _files), do: type

  # A version of a video type has a video, not captions alone, a version of `proposal`
  # exactly one Markdown file, and a mockup of pages passes the mockup checks
  # (`Apiary.Artifacts.Mockup.check_version/1`); else every staged copy is dropped.
  defp complete(%Type{base_view: :video}, staged) do
    if Format.video?(Enum.map(staged, & &1.content_type)),
      do: :ok,
      else: incomplete(staged, :no_video)
  end

  defp complete(%Type{standard: true, name: "proposal"} = type, staged) do
    if Format.stored?(type, Enum.map(staged, & &1.content_type)),
      do: :ok,
      else: incomplete(staged, :one_markdown)
  end

  defp complete(%Type{base_view: :mockup}, staged) do
    case Mockup.check_version(Enum.map(staged, &{&1.filename, &1.staged.path})) do
      :ok -> :ok
      {:error, refusal} -> incomplete(staged, refusal)
    end
  end

  defp complete(_type, _staged), do: :ok

  defp incomplete(staged, reason) do
    store = Store.impl()
    Enum.each(staged, &store.discard(&1.staged))
    {:error, {:invalid, reason}}
  end

  defp stage_one(store, type, index, filename, source, left) do
    case store.stage(source, left) do
      {:ok, staged} ->
        case Format.check(type, filename, staged.path) do
          {:ok, content_type} ->
            {:ok,
             %{
               staged: staged,
               filename: filename,
               content_type: content_type,
               size: staged.size,
               sha256: staged.sha256
             }}

          {:error, {:schema, detail}} ->
            store.discard(staged)
            {:error, {:invalid, {:schema, index, detail}}}

          {:error, reason} ->
            store.discard(staged)
            {:error, {:invalid, {reason, index}}}
        end

      {:error, :too_large} ->
        {:error, {:too_large, type.size_limit}}

      {:error, :unreadable} ->
        {:error, {:invalid, {:unreadable, index}}}

      {:error, reason} ->
        Logger.error(
          "The artifact store could not stage a file of type #{type.name}: #{shape(reason)}"
        )

        {:error, :store_unavailable}
    end
  end

  # Keeps each staged file in the store, in order. When one cannot be kept, every staged
  # copy left is dropped and the push is `{:error, :store_unavailable}`; the files kept
  # before it stay in the store with no version. They are not deleted: the store has no
  # delete path, and a content address may be a file of another version. A stored file
  # that no version links to is harmless, and a later push of the same content uses it.
  defp commit_all(staged) do
    store = Store.impl()

    staged
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case store.commit(file.staged) do
        {:ok, key} -> {:cont, {:ok, [Map.put(file, :store_key, key) | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, stored} ->
        {:ok, Enum.reverse(stored)}

      {:error, reason} ->
        Logger.error("The artifact store could not keep a staged file: #{shape(reason)}")
        Enum.each(staged, &store.discard(&1.staged))
        {:error, :store_unavailable}
    end
  end

  # The rows, with the staged files kept in the store after every check passed, last
  # before the file rows. The checks include the run's watch entry (`watch_entry/3`), formed
  # before `keep/6` and written after it. On a refusal, or an exception, which is raised
  # again, every staged copy is dropped, those `integers/2` made included (`keep/6`), so a
  # refused push keeps no file in the store.
  defp write(writer, work_item, type, fields, staged) do
    Repo.transact(fn ->
      now = DateTime.utc_now()

      with :ok <- shown_kept(work_item, type),
           %WorkItem{} = held <- held_work_item(work_item),
           :ok <- run_live(writer),
           :ok <- stage_kept(held, fields.expect_stage),
           :ok <- type_kept(type),
           {:ok, artifact} <- artifact(held, type, fields, now),
           :ok <- members_kept(writer, artifact, staged),
           :ok <- verdict_kept(held, artifact, fields, staged),
           :ok <- decision_kept(held, fields.decision),
           {:ok, watched} <- watch_entry(writer, held, type),
           {:ok, kept} <- integers(type, staged),
           {:ok, _written} = written <- keep(writer, held, artifact, fields, kept, now) do
        :ok = append_watch(watched)
        written
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
    |> case do
      {:ok, _written} = written ->
        written

      {:error, _reason} = error ->
        discard(staged)
        error
    end
  rescue
    exception ->
      discard(staged)
      reraise exception, __STACKTRACE__
  end

  # The version, its audit entry, then the files kept in the store and their rows. A
  # refusal or an exception drops the staged copies `kept`, which `integers/2` may have
  # made; the exception is raised again.
  defp keep(writer, held, artifact, fields, kept, now) do
    with {:ok, version} <- version(artifact, writer, fields, now),
         :ok <- audit_push(writer, held, artifact, version),
         {:ok, stored} <- commit_all(kept),
         :ok <- insert_files(version, stored) do
      {:ok, {Repo.preload(%{version | artifact: artifact}, files: files_query()), held}}
    else
      {:error, _reason} = error ->
        discard(kept)
        error
    end
  rescue
    exception ->
      discard(kept)
      reraise exception, __STACKTRACE__
  end

  # The `watch` entry for the version a run stores of its submission type: the type in
  # `submit.type` of the run's process version (`Processes.harness_template/1`). The entry
  # goes to the feed of the adapter of the work item's target collection, the collection
  # the run's work entry comes from (`RunCredentials.work_collection/3`), and contains the
  # work item's public id and its stable url. `{:ok, {adapter, entry}}` for an entry,
  # `{:ok, nil}` for none: a member action's version, a version of another type, a run
  # whose process version has no submit, a work item with no target, or a target that no
  # collection matches.
  #
  # The entry is formed before `keep/6`, and `append_watch/1` writes it after, in the
  # push's transaction, so the version and its entry commit together or not at all. The
  # work item's lock is held for both, and the feed's counter is taken last, as in the
  # core's lock order (`Apiary.Adapters.Collections`).
  #
  # A standard type is never a submission type: a template's `submit.type` is a custom
  # type with `base_view: structured` (`Apiary.Artifacts.TemplateTypes`). A push of a
  # standard type, the verdict of every stage among them, returns before it reads the
  # run or its process version. A withdrawal has no entry (`write_withdrawal/4`).
  #
  # The lookup and `Processes.harness_template/1` only read the database: no message is
  # sent and no other system is called inside the transaction. `Feed.append/2` takes only
  # an adapter with no organisation, which the `nodes` check keeps true of every adapter;
  # any other node gets no entry.
  #
  # `{:error, :public_url}` where the stable url is not one a watch entry takes: the
  # instance's `PUBLIC_URL` is plain http to a host other than `localhost`, `127.0.0.1`
  # or `[::1]`, or has a character outside RFC 3986, such as a host in Unicode. The boot
  # accepts both (`config/runtime.exs`), and the error is logged with the fix. It comes
  # before `keep/6`, so a refused push keeps no file in the store.
  defp watch_entry(%{actor: :run, run_id: run_id}, held, %Type{standard: false, name: name}) do
    with %DispatchRun{} = dispatch_run <- Repo.get(DispatchRun, run_id),
         ^name <- submit_type(dispatch_run),
         %{} = target <- target(held),
         {_collection, _connection, %Node{kind: :adapter, organisation_id: nil} = adapter} <-
           RunCredentials.work_collection(dispatch_run, held, target) do
      url = WorkItems.stable_url(held)

      if Feed.work_item_url?(url) do
        {:ok, {adapter, %{kind: "watch", work_item_id: held.public_id, url: url}}}
      else
        Logger.error(
          "Set PUBLIC_URL to an https:// address: a run cannot store its submission with this one."
        )

        {:error, :public_url}
      end
    else
      _no_entry -> {:ok, nil}
    end
  end

  defp watch_entry(_writer, _held, _type), do: {:ok, nil}

  defp append_watch(nil), do: :ok

  defp append_watch({adapter, entry}) do
    {:ok, _seq} = Feed.append(adapter, entry)
    :ok
  end

  # submit_type/1 is the type in `submit.type` of the run's process version, or of the
  # process version the work item runs under (`Processes.version_for/1`), which is what the
  # Submissions list reads; nil for none.
  @doc false
  @spec submit_type(DispatchRun.t() | WorkItem.t()) :: String.t() | nil
  def submit_type(%DispatchRun{process_version_id: id}),
    do: submit_of(Processes.harness_template(id))

  def submit_type(%WorkItem{} = work_item),
    do: work_item |> Processes.version_for() |> Processes.harness_template() |> submit_of()

  defp submit_of(%{"submit" => %{"type" => type}}) when is_binary(type), do: type
  defp submit_of(_template), do: nil

  # The work item's target, as a run's claim reads it (`Apiary.Dispatches.Handover`), nil
  # for none.
  defp target(%WorkItem{target_system: system, target_path: path})
       when is_binary(system) and is_binary(path),
       do: %{system: system, path: path}

  defp target(%WorkItem{}), do: nil

  # Drops staged copies; one kept in the store already has no staged copy left.
  defp discard(staged) do
    store = Store.impl()
    Enum.each(staged, &store.discard(&1.staged))
  end

  # A run's version of the questions or the review comments, checked against the
  # artifact's newest version under the work item's lock: what members wrote stays
  # (`Apiary.Explore.Questions.check_run/3`, `Apiary.Explore.ReviewComments.check_run/4`),
  # else `{:invalid, {:kept, 0, reason}}`. The format check passed, so the file is one
  # JSON document of the type's format. A newest version whose file cannot be read is
  # `{:error, :store_unavailable}`, never taken for no version, which would let the run
  # drop what members wrote; so are the newest questions a review comments check reads.
  defp members_kept(%{writer: :run, run_id: run_id}, %Artifact{type: type} = artifact, [file])
       when type in @member_types do
    module = if type == "questions", do: Questions, else: ReviewComments

    number =
      Repo.one(
        from r in Apiary.Runs.Run.registered(),
          where: r.dispatch_run_id == ^run_id,
          select: r.number
      )

    with {:ok, newest} <- newest_document(module, artifact),
         {:ok, question_ids} <- question_ids(module, artifact) do
      with {:ok, text} <- File.read(file.staged.path),
           %{} = document <- module.decode(text) do
        with :ok <- check_run(module, newest, document, number || 0, question_ids),
             :ok <- abouts_kept(module, artifact, newest, document) do
          :ok
        else
          {:error, :store_unavailable} = error -> error
          {:error, reason} -> {:error, {:invalid, {:kept, 0, reason}}}
        end
      else
        _unreadable -> {:error, {:invalid, {:unreadable, 0}}}
      end
    end
  end

  defp members_kept(_writer, _artifact, _stored), do: :ok

  # The `about` of each question that a run's version of the questions adds, or whose
  # `about` it changes (`Apiary.Explore.Questions.abouts/2`), points at an output of the
  # work item: an artifact of its `type` and `name` whose newest version that no cancelled
  # run wrote is no withdrawal, else `{:error, {:about, id, type, name}}`. An `item` of the
  # acceptance criteria is the id of a criterion in some version of them that no cancelled
  # run wrote, a criterion removed or dropped later too, else
  # `{:error, {:about_item, id, type, name, item}}`; an item of another type is not
  # checked, because Qory Apiary does not read the entries of other outputs. The abouts
  # are checked in the questions' order, and each output is read once per push: its
  # versions in one query, and, for an item, the file of each of its versions once
  # (`output_read/3`). A file that cannot be read is `{:error, :store_unavailable}`.
  defp abouts_kept(Questions, artifact, newest, document) do
    newest
    |> Questions.abouts(document)
    |> Enum.reduce_while({:ok, %{}}, fn {id, about}, {:ok, outputs} ->
      case about_kept(artifact.work_item_id, id, about, outputs) do
        {:ok, outputs} -> {:cont, {:ok, outputs}}
        refused -> {:halt, refused}
      end
    end)
    |> case do
      {:ok, _outputs} -> :ok
      refused -> refused
    end
  end

  defp abouts_kept(_module, _artifact, _newest, _document), do: :ok

  defp about_kept(_work_item_id, _id, %{"work_item" => true}, outputs), do: {:ok, outputs}

  defp about_kept(work_item_id, id, %{"type" => type, "name" => name} = about, outputs) do
    item = if type == "acceptance-criteria", do: about["item"]

    with {:ok, output, outputs} <- output_read(outputs, {work_item_id, type, name}, item) do
      cond do
        output.versions == [] or hd(output.versions).withdrawn ->
          {:error, {:about, id, type, name}}

        is_nil(item) or MapSet.member?(output.items, item) ->
          {:ok, outputs}

        true ->
          {:error, {:about_item, id, type, name, item}}
      end
    end
  end

  # The output `{work_item_id, type, name}` as `outputs` read it in this push, else read
  # now: `%{versions:, items:}`, its versions that no cancelled run wrote, newest first,
  # (`output_versions/1`), and, where an `item` asks for them, the ids of the criteria in
  # any of those versions, nil until then. Returns the output and `outputs` with it.
  defp output_read(outputs, key, item) do
    output = Map.get_lazy(outputs, key, fn -> %{versions: output_versions(key), items: nil} end)

    case output do
      %{items: nil, versions: versions} when is_binary(item) ->
        with {:ok, items} <- criterion_ids(versions) do
          output = %{output | items: items}
          {:ok, output, Map.put(outputs, key, output)}
        end

      output ->
        {:ok, output, Map.put(outputs, key, output)}
    end
  end

  # Every version of the acceptance criteria, whose items are read; the newest alone of
  # any other output.
  defp output_versions({work_item_id, type, name}) do
    query =
      from v in Version,
        as: :version,
        join: a in assoc(v, :artifact),
        where: a.work_item_id == ^work_item_id and a.type == ^type and a.name == ^name,
        where: not exists(Apiary.Runs.Run.cancelled_dispatch_run(:version, :run_id)),
        order_by: [desc: v.number],
        preload: [files: ^files_query()]

    if type == "acceptance-criteria",
      do: Repo.all(query),
      else: Repo.all(from v in query, limit: 1)
  end

  # The ids of the criteria in each version of the acceptance criteria that is no
  # withdrawal, each version's file read once. A push with a criterion item reads every
  # criteria version's file once.
  defp criterion_ids(versions) do
    Enum.reduce_while(versions, {:ok, MapSet.new()}, fn
      %Version{withdrawn: true}, acc ->
        {:cont, acc}

      version, {:ok, ids} ->
        case Apiary.Stages.Artifacts.stored_json(version) do
          {:ok, %{"criteria" => criteria}} when is_list(criteria) ->
            {:cont, {:ok, Enum.reduce(criteria, ids, &criterion_id/2)}}

          {:ok, _none} ->
            {:cont, {:ok, ids}}

          {:error, :store_unavailable} = error ->
            {:halt, error}
        end
    end)
  end

  defp criterion_id(%{"id" => id}, ids) when is_binary(id), do: MapSet.put(ids, id)
  defp criterion_id(_criterion, ids), do: ids

  # A verdict, checked under the work item's lock: its `track`, where it has one, is a track
  # that the gate of the stage the version is made in offers (`track_offered/3`); and the
  # question of each `answer` point is open in the newest questions, and is a question of the
  # work item's current take in (`Apiary.Explore.Questions.open_in_take_in/2`), so the person
  # can answer it; else `{:invalid, {:kept, 0, {:not_open, point, question}}}`, with `point`
  # counted from 1. The format check passed, so the file is one JSON document of the
  # verdict's format. The newest questions, where their file cannot be read, are
  # `{:error, :store_unavailable}`.
  defp verdict_kept(%WorkItem{} = held, %Artifact{type: "verdict"}, fields, [file]) do
    with {:ok, text} <- File.read(file.staged.path),
         {:ok, %{} = document} <- Jason.decode(text),
         :ok <- track_offered(held, fields.stage_id, document) do
      case answer_points(document) do
        [] -> :ok
        answers -> answers_open(held, answers)
      end
    else
      {:error, {:invalid, _reason}} = refused -> refused
      _unreadable -> {:error, {:invalid, {:unreadable, 0}}}
    end
  end

  defp verdict_kept(_held, _artifact, _fields, _staged), do: :ok

  # The gate of the stage `stage_id` of the work item's process version offers the track of
  # the verdict, `%{"track" => %{"id" => id}}`; no stage, or a stage whose gate offers none,
  # offers none.
  defp track_offered(held, stage_id, %{"track" => %{"id" => id}}) when is_binary(id) do
    stage = held |> Processes.version_for() |> Processes.stage(stage_id)
    ids = (stage && get_in(stage, ["gate", "tracks"])) || []

    if id in ids,
      do: :ok,
      else:
        {:error,
         {:invalid, {:track_not_offered, %{stage: stage && stage["name"], ids: ids, id: id}}}}
  end

  defp track_offered(_held, _stage_id, _document), do: :ok

  defp answer_points(%{"points" => points}) when is_list(points) do
    for {%{"action" => "answer", "question" => question}, point} <- Enum.with_index(points, 1),
        do: {point, question}
  end

  defp answer_points(_document), do: []

  defp answers_open(held, answers) do
    with {:ok, newest} <- Questions.current(held) do
      document = if newest, do: elem(newest, 1)

      open =
        document
        |> Questions.open_in_take_in(Questions.take_in_runs(held.id, held.take_in || 0))
        |> MapSet.new(& &1["id"])

      case Enum.find(answers, fn {_point, question} -> not MapSet.member?(open, question) end) do
        nil -> :ok
        {point, question} -> {:error, {:invalid, {:kept, 0, {:not_open, point, question}}}}
      end
    end
  end

  # The document of the artifact's newest version: `{:ok, nil}` for no version.
  defp newest_document(module, artifact) do
    case Repo.one(
           from v in Version,
             where: v.artifact_id == ^artifact.id,
             order_by: [desc: v.number],
             limit: 1,
             preload: [files: ^files_query()]
         ) do
      nil -> {:ok, nil}
      version -> module.loaded(version)
    end
  end

  # The question of a reply with the outcome `asked` is the id of a question of the newest
  # questions stored now, under the work item's lock.
  defp question_ids(Questions, _artifact), do: {:ok, []}

  defp question_ids(ReviewComments, artifact) do
    case Questions.current(%WorkItem{
           id: artifact.work_item_id,
           workspace_id: artifact.workspace_id
         }) do
      {:ok, {_version, questions}} -> {:ok, Questions.ids(questions)}
      {:ok, nil} -> {:ok, []}
      {:error, :store_unavailable} = error -> error
    end
  end

  # The questions or the review comments, staged, with each number that is an integer in
  # value written as an integer (the moduledoc): the one staged file as it is when it has
  # none, else the document re-encoded, staged within the type's size limit and checked
  # in its place, and the first staged copy dropped. A float past 2^53 stays as it is: no
  # run number or version is that large, and its digits would grow the file.
  defp integers(%Type{name: name} = type, [%{filename: filename} = file] = staged)
       when name in @member_types do
    with {:ok, text} <- File.read(file.staged.path),
         {:ok, document} <- Jason.decode(text),
         normal = integer_values(document),
         false <- normal === document do
      bytes = Jason.encode!(normal)

      case stage_one(Store.impl(), type, 0, filename, {:binary, bytes}, type.size_limit) do
        {:ok, normalised} ->
          discard(staged)
          {:ok, [normalised]}

        {:error, _refusal} = error ->
          error
      end
    else
      true -> {:ok, staged}
      _unreadable -> {:error, :store_unavailable}
    end
  end

  defp integers(_type, staged), do: {:ok, staged}

  @max_exact 9_007_199_254_740_992

  defp integer_values(value) when is_float(value) and abs(value) <= @max_exact do
    integer = trunc(value)
    if integer == value, do: integer, else: value
  end

  defp integer_values(%{} = object),
    do: Map.new(object, fn {key, value} -> {key, integer_values(value)} end)

  defp integer_values(list) when is_list(list), do: Enum.map(list, &integer_values/1)
  defp integer_values(value), do: value

  defp check_run(Questions, newest, document, number, _question_ids),
    do: Questions.check_run(newest, document, number)

  defp check_run(ReviewComments, newest, document, number, question_ids),
    do: ReviewComments.check_run(newest, document, number, question_ids)

  # A standard type a workspace can hide: the row of the workspace the push read, locked
  # `FOR SHARE` until the push commits, and its list read again. A standard type has no
  # row to lock, so a change of the list, which locks the workspace's row
  # `FOR NO KEY UPDATE`, runs before or after the push and not between its check and its
  # rows. A work item
  # moved since the read fails `held_work_item/1`. nil once the workspace is gone.
  defp shown_kept(%WorkItem{workspace_id: workspace_id}, %Type{standard: true, name: name}) do
    if name in Type.always_on() do
      :ok
    else
      case Repo.one(
             from w in Workspace,
               where: w.id == ^workspace_id,
               lock: "FOR SHARE",
               select: {w.id, w.shown_standard_types}
           ) do
        nil -> nil
        {_id, shown} -> if shown?(name, shown), do: :ok, else: {:error, {:unknown_type, name}}
      end
    end
  end

  defp shown_kept(_work_item, %Type{}), do: :ok

  # The work item held `FOR UPDATE`, where it was when the push read it; nil once it
  # moved to another workspace or went.
  defp held_work_item(%WorkItem{id: id, workspace_id: workspace_id}) do
    Repo.one(
      from w in WorkItem,
        where: w.id == ^id and w.workspace_id == ^workspace_id,
        lock: "FOR UPDATE"
    )
  end

  # A run's push: its run of the queue read again under the work item's lock, so a run
  # that ended since the caller's check pushes nothing, `{:error, :run_ended}`, and
  # neither does one a member cancelled since, `{:error, :run_cancelled}`. The end
  # of a run holds its work item before it ends the run of the queue and stores what the
  # run gave (`Apiary.Dispatches.RunEnd.hold/1`, `Apiary.Dispatches.Settle`), and so does
  # a member's cancel before it marks the run (`Apiary.Runs.Cancel`), so the end, the
  # cancel and the push take turns at the work item: the end reads every version the push
  # stored, or the push reads the run ended or cancelled.
  defp run_live(%{writer: :run, run_id: run_id}) do
    case Repo.one(
           from d in DispatchRun,
             left_join: r in Apiary.Runs.Run,
             on: r.dispatch_run_id == d.id,
             where: d.id == ^run_id,
             select: {d.state, r.cancel_requested_at}
         ) do
      nil -> {:error, :not_found}
      {_state, %DateTime{}} -> {:error, :run_cancelled}
      {:ended, _marked} -> {:error, :run_ended}
      _live -> :ok
    end
  end

  defp run_live(_writer), do: :ok

  # The held work item's stage against `opts[:expect_stage]`, as `Keyword.fetch/2` read it:
  # nil is a value, a work item with no stage, and `:error` is an option not given.
  defp stage_kept(_held, :error), do: :ok
  defp stage_kept(%WorkItem{stage_id: stage_id}, {:ok, stage_id}), do: :ok
  defp stage_kept(_held, {:ok, _other}), do: {:error, :stage_changed}

  # A custom type locked `FOR SHARE` until the push commits, so a deletion of the type,
  # which locks it `FOR UPDATE` before it counts the artifacts of its name, runs before or
  # after the push and not between its check and its rows.
  defp type_kept(%Type{standard: true}), do: :ok

  defp type_kept(%Type{id: id, name: name}) do
    case Repo.one(from t in Type, where: t.id == ^id, lock: "FOR SHARE", select: t.id) do
      nil -> {:error, {:unknown_type, name}}
      _id -> :ok
    end
  end

  defp artifact(held, type, fields, now) do
    case Repo.one(
           from a in Artifact,
             where: a.work_item_id == ^held.id and a.type == ^type.name and a.name == ^fields.name
         ) do
      %Artifact{} = artifact ->
        {:ok, artifact}

      nil ->
        PublicId.Insert.insert(%Artifact{
          public_id: PublicId.generate(Artifact.prefix()),
          organisation_id: held.organisation_id,
          workspace_id: held.workspace_id,
          work_item_id: held.id,
          type: type.name,
          name: fields.name,
          stage_id: fields.stage_id,
          inserted_at: now
        })
    end
  end

  defp version(artifact, writer, fields, now) do
    highest =
      Repo.one(from v in Version, where: v.artifact_id == ^artifact.id, select: max(v.number))

    PublicId.Insert.insert(%Version{
      public_id: PublicId.generate(Version.prefix()),
      organisation_id: artifact.organisation_id,
      workspace_id: artifact.workspace_id,
      artifact_id: artifact.id,
      number: (highest || 0) + 1,
      writer: writer.writer,
      run_id: writer.run_id,
      user_id: writer.user_id,
      stage_id: fields.stage_id,
      note: fields.note,
      decision_id: fields.decision,
      withdrawn: Map.get(fields, :withdrawn, false),
      inserted_at: now
    })
  end

  defp insert_files(version, stored) do
    rows =
      for file <- stored do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: version.organisation_id,
          workspace_id: version.workspace_id,
          version_id: version.id,
          filename: file.filename,
          content_type: file.content_type,
          size: file.size,
          sha256: file.sha256,
          store_key: file.store_key
        }
      end

    {count, _rows} = Repo.insert_all(ArtifactFile, rows)

    if count == length(rows) do
      :ok
    else
      Logger.error("A push wrote #{count} of its #{length(rows)} file rows")
      {:error, :store_unavailable}
    end
  end

  defp audit_push(%{writer: :run}, _work_item, _artifact, _version), do: :ok

  defp audit_push(%{writer: :person, scope: scope}, work_item, artifact, version) do
    with {:ok, _entry} <-
           Audit.record(Repo, scope, @write, work_item, %{
             details: %{
               "artifact_id" => artifact.public_id,
               "version_id" => version.public_id,
               "type" => artifact.type,
               "name" => artifact.name,
               "number" => version.number
             }
           }),
         do: :ok
  end

  ## Reading

  @doc false
  @spec list(WorkItem.t()) :: [Artifact.t()]
  def list(%WorkItem{id: id, workspace_id: workspace_id}) do
    Repo.all(
      from a in Artifact,
        where: a.work_item_id == ^id and a.workspace_id == ^workspace_id,
        order_by: [a.type, a.name],
        preload: [
          versions: ^{versions_query(), [:user, run: [run: runs_query()], files: files_query()]}
        ]
    )
  end

  @doc false
  @spec versions(Artifact.t()) :: [Version.t()]
  def versions(%Artifact{id: id}) do
    Repo.all(
      from v in versions_query(),
        where: v.artifact_id == ^id,
        preload: [
          :user,
          run: [run: ^runs_query()],
          files: ^files_query()
        ]
    )
  end

  @doc false
  @spec newest(WorkItem.t(), String.t(), String.t()) :: Version.t() | nil
  def newest(%WorkItem{id: id, workspace_id: workspace_id}, type, name \\ "main") do
    Repo.one(
      from v in Version,
        join: a in assoc(v, :artifact),
        where:
          a.work_item_id == ^id and a.workspace_id == ^workspace_id and a.type == ^type and
            a.name == ^name,
        order_by: [desc: v.number],
        limit: 1,
        preload: [
          :user,
          run: [run: ^runs_query()],
          artifact: a,
          files: ^files_query()
        ]
    )
  end

  @doc false
  @spec get_version!(String.t()) :: Version.t()
  def get_version!(id) do
    unless PublicId.valid?(Version.prefix(), id),
      do: raise(Ecto.NoResultsError, queryable: Version)

    Repo.one!(
      from v in Version,
        where: v.public_id == ^id,
        preload: [
          :artifact,
          :user,
          run: [run: ^runs_query()],
          files: ^files_query()
        ]
    )
  end

  # The run a run of the queue registered when it was claimed (`Apiary.Runs.Run`), for its
  # number and its page: its id, public id and number, `dispatch_run_id`, which the
  # preload needs to match each run to its run of the queue, and a member's cancel of it
  # (`cancelled?/1`).
  defp runs_query,
    do:
      from(r in Apiary.Runs.Run.registered(),
        select:
          struct(r, [
            :id,
            :public_id,
            :number,
            :dispatch_run_id,
            :cancel_requested_at,
            :cancel_requested_by_id
          ])
      )

  # with_sessions/1 reads the sessions of each version's run, and whether its stage's
  # sequence has a loop (`loop`, nil where the run's process version or stage is not
  # found), into a version, a list of versions, or a list of artifacts with their
  # versions, as `list/1` returns them. Only `ApiaryWeb.ArtifactComponents.writer/2`
  # needs them, for the round.
  @doc false
  @spec with_sessions(Version.t() | [Version.t() | Artifact.t()]) ::
          Version.t() | [Version.t() | Artifact.t()]
  def with_sessions([%Artifact{} | _rest] = artifacts) do
    artifacts = Repo.preload(artifacts, versions: [run: [sessions: sessions_query()]])
    loops = artifacts |> Enum.flat_map(& &1.versions) |> loops()
    Enum.map(artifacts, &%{&1 | versions: Enum.map(&1.versions, fn v -> with_loop(v, loops) end)})
  end

  def with_sessions(versions) do
    versions = Repo.preload(versions, run: [sessions: sessions_query()])
    loops = versions |> List.wrap() |> loops()

    if is_list(versions),
      do: Enum.map(versions, &with_loop(&1, loops)),
      else: with_loop(versions, loops)
  end

  defp with_loop(%{run: %DispatchRun{} = run} = version, loops),
    do: %{version | run: %{run | loop: loops[{run.process_version_id, run.stage_id}]}}

  defp with_loop(version, _loops), do: version

  # Whether the stage has a loop in its sequence, by process version id and stage id, for
  # each run of `versions` that has sessions.
  defp loops(versions) do
    keys =
      for %{run: %DispatchRun{sessions: [_ | _]} = run} <- versions,
          is_binary(run.process_version_id),
          uniq: true,
          do: {run.process_version_id, run.stage_id}

    stage_loops(keys)
  end

  defp stage_loops([]), do: %{}

  defp stage_loops(keys) do
    documents =
      Repo.all(
        from v in ProcessVersion,
          where: v.id in ^Enum.map(keys, &elem(&1, 0)),
          select: {v.id, v.document}
      )
      |> Map.new()

    # A stage the document does not have is left out: its `loop` stays nil, unknown.
    for {version_id, stage_id} = key <- keys,
        stage = Apiary.Processes.stage(documents[version_id], stage_id),
        into: %{},
        do: {key, Apiary.Stages.Runner.first_loop(stage) != nil}
  end

  # The sessions of a run of a stage with `shared_run: true`: their place and when each
  # was written, in the order they ran.
  defp sessions_query,
    do:
      from(s in Apiary.Stages.Session,
        order_by: s.sequence,
        select:
          struct(s, [
            :id,
            :dispatch_run_id,
            :sequence,
            :round,
            :stage_entry,
            :loop_entry,
            :inserted_at
          ])
      )

  # cancelled?/1 is whether a run a member cancelled wrote `version`
  # (`Apiary.Runs.Run.cancel_requested?/1`), as `list/1` and the other reads here preload
  # its run: such a version stays, marked, and counts for no stage. False for a person's
  # version.
  @doc false
  @spec cancelled?(Version.t() | map) :: boolean
  def cancelled?(%{writer: :run, run: %{run: run}}), do: Apiary.Runs.Run.cancel_requested?(run)
  def cancelled?(_version), do: false

  # name_order/1 is the sort key of an artifact's name among the names of one type: `main`
  # first, then the others by their words, a number among them by its value, so
  # `scenario-2` comes before `scenario-10`.
  @doc false
  @spec name_order(String.t()) :: {boolean, [String.t() | integer]}
  def name_order(name) when is_binary(name) do
    parts =
      for part <- Regex.split(~r/(\d+)/, name, include_captures: true, trim: true),
          do: if(part =~ ~r/^\d+$/, do: String.to_integer(part), else: part)

    {name != "main", parts}
  end

  # newest_counted/1 is the newest version of `artifact` that no run a member cancelled
  # wrote (`cancelled?/1`), for versions newest first; nil for none.
  @doc false
  @spec newest_counted(Artifact.t() | map) :: Version.t() | map | nil
  def newest_counted(%{versions: versions}) when is_list(versions),
    do: Enum.find(versions, &(not counted_out?(&1)))

  def newest_counted(_artifact), do: nil

  # withdrawn?/1 is whether the newest version of `artifact` that no cancelled run wrote
  # (`cancelled?/1`) is a withdrawal (`withdraw/4`), for an artifact whose versions are
  # newest first, as `list/1` reads them and `Apiary.Stages.artifact_index/1` returns them,
  # with `cancelled` set. A withdrawal by a run a member cancelled counts for nothing, as
  # every other version that run wrote. False for an artifact with no such version.
  @doc false
  @spec withdrawn?(Artifact.t() | map) :: boolean
  def withdrawn?(%{versions: versions}) when is_list(versions),
    do: match?(%{withdrawn: true}, Enum.find(versions, &(not counted_out?(&1))))

  def withdrawn?(_artifact), do: false

  defp counted_out?(%{cancelled: cancelled}) when is_boolean(cancelled), do: cancelled
  defp counted_out?(version), do: cancelled?(version)

  # not_withdrawn_name/0 is the condition, on an artifact bound as `:artifact`, that its
  # newest version that no cancelled run wrote is not a withdrawal: the rule of
  # `withdrawn?/1` in SQL.
  @doc false
  @spec not_withdrawn_name() :: Ecto.Query.dynamic_expr()
  def not_withdrawn_name do
    dynamic(
      [artifact: a],
      fragment(
        "NOT coalesce((SELECT n.withdrawn FROM artifact_versions n WHERE n.artifact_id = ? AND NOT EXISTS (SELECT 1 FROM runs r WHERE r.dispatch_run_id = n.run_id AND r.cancel_requested_at IS NOT NULL) ORDER BY n.number DESC LIMIT 1), false)",
        a.id
      )
    )
  end

  @doc false
  @spec open_file(ArtifactFile.t()) :: {:ok, Path.t() | Enumerable.t()} | {:error, term}
  def open_file(%ArtifactFile{store_key: key}), do: Store.impl().open(key)

  # exists?/3 is whether `stage_id` made a stored version of `type_name` (`made_in/3`).
  @doc false
  @spec exists?(WorkItem.t(), String.t(), String.t()) :: boolean
  def exists?(%WorkItem{} = work_item, stage_id, type_name)
      when is_binary(stage_id) and is_binary(type_name) do
    workspace = %Workspace{id: work_item.workspace_id, organisation_id: work_item.organisation_id}

    case type(workspace, type_name) do
      %Type{} = type ->
        work_item
        |> made_in(stage_id, type_name)
        |> Enum.any?(&Format.stored?(type, &1))

      nil ->
        false
    end
  end

  def exists?(%WorkItem{}, _stage_id, _type_name), do: false

  # The content types of the files of each version of `type`, of any name, made in
  # `stage_id`, but by a run a member cancelled (`cancelled?/1`) and of a name whose newest
  # version is a withdrawal (`withdrawn?/1`): a list per version. A version here has one
  # file or more, so a withdrawal, which has none, is never in the list.
  defp made_in(%WorkItem{id: id, workspace_id: workspace_id}, stage_id, type) do
    Repo.all(
      from v in Version,
        as: :version,
        join: a in assoc(v, :artifact),
        as: :artifact,
        join: f in assoc(v, :files),
        where:
          a.work_item_id == ^id and a.workspace_id == ^workspace_id and a.type == ^type and
            v.stage_id == ^stage_id,
        where: not exists(Apiary.Runs.Run.cancelled_dispatch_run(:version, :run_id)),
        where: ^not_withdrawn_name(),
        group_by: v.id,
        select: fragment("array_agg(?)", f.content_type)
    )
  end

  defp versions_query, do: from(v in Version, order_by: [desc: v.number])
  defp files_query, do: from(f in ArtifactFile, order_by: f.filename)
end

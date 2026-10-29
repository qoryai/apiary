defmodule ApiaryWeb.HarnessTargets do
  # The handling of a workspace's destinations, each with its Stack select
  # (`ApiaryWeb.HarnessComponents.targets/1`), shared by the set-up's Harness step
  # (`ApiaryWeb.WorkspaceSetupLive`) and Workspace settings › Workflow
  # (`ApiaryWeb.WorkflowLive`).
  #
  # The functions take and return the page's socket. They read the assigns
  # `current_scope`; `chosen`, the workspace's harness (`Apiary.Stacks.Sources.chosen/1`);
  # `may`, whether `harness.save` allows the person; `linked`, the connected repositories,
  # nil while they are listed; `harness_targets` (`targets/3`); and they write
  # `target_edit`, the destination being saved or chosen for, and `workspace_stacks` with
  # `workspace_stacks_of`, the stacks the workspace's harness exports and the read they
  # come from. `saved` is the page's function that takes the answer of a save,
  # `saved.(socket, choice, result)`, with `result` as
  # `Apiary.Stacks.Sources.choose_target/3` returns it.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use ApiaryWeb, :html

  import Phoenix.LiveView, only: [cancel_async: 2, connected?: 1, put_flash: 3, start_async: 3]

  alias Apiary.Lingo.Domain.Definition
  alias Apiary.Stacks.Sources
  alias Apiary.WorkspaceSetup
  alias ApiaryWeb.HarnessComponents

  @doc false
  # targets/3 is the destinations of `workspace` of the type `domain`, the rows of the
  # Destinations step's list it ticked, one per target, each with the stack chosen for it,
  # nil for none.
  @spec targets(Apiary.Accounts.Scope.t(), Apiary.Organisations.Workspace.t(), module) :: [map]
  def targets(scope, workspace, domain) do
    chosen = Sources.targets_chosen(workspace)

    for {_adapter, rows} <- WorkspaceSetup.collections(scope, domain, :destinations),
        row <- rows,
        WorkspaceSetup.ticked?(:destinations, row, workspace) do
      %{collection: collection} = row
      target = %{system: collection.target_system, path: collection.target_path}

      %{
        id: collection.public_id,
        title: collection.title,
        target: target,
        chosen: chosen[{target.system, target.path}]
      }
    end
    |> Enum.uniq_by(& &1.target)
  end

  @doc false
  # kept_edit/3 is the edit of a destination as the page reads its destinations again:
  # kept while the destination is listed and the person may save, else nil.
  @spec kept_edit(map | nil, [map], boolean) :: map | nil
  def kept_edit(%{id: id} = edit, targets, true) do
    case Enum.find(targets, &(&1.id == id)) do
      nil -> nil
      target -> %{edit | target: target.target}
    end
  end

  def kept_edit(_edit, _targets, _may), do: nil

  @doc false
  # read_workspace_stacks/1 assigns the stacks the workspace's saved harness exports, as a
  # destination's Stack offers them: the Qory harness's from the release's list, with no
  # read; a harness repository's read outside the page's process at the `ref` a run reads
  # it at, once per repository and `ref`, where a person who may save has a destination.
  @spec read_workspace_stacks(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def read_workspace_stacks(%{assigns: %{chosen: %{choice: :qory}}} = socket),
    do:
      assign(socket, workspace_stacks: Definition.qory_harness().stacks, workspace_stacks_of: nil)

  def read_workspace_stacks(%{assigns: %{may: true, harness_targets: [_ | _]}} = socket) do
    %{chosen: chosen, current_scope: scope} = socket.assigns
    of = {chosen.git, chosen.pin}

    cond do
      socket.assigns.workspace_stacks_of == of ->
        socket

      connected?(socket) ->
        source = HarnessComponents.exports_source(chosen)

        socket
        |> assign(workspace_stacks: nil, workspace_stacks_of: of)
        |> cancel_async(:workspace_stacks)
        |> start_async(:workspace_stacks, fn -> {of, Sources.exports(scope, source)} end)

      true ->
        assign(socket, workspace_stacks: nil, workspace_stacks_of: nil)
    end
  end

  def read_workspace_stacks(socket),
    do: assign(socket, workspace_stacks: nil, workspace_stacks_of: nil)

  @doc false
  # workspace_stacks_read/3 keeps the stacks of the read `of`, where it is still the one
  # read: the names it exports, none for a read that failed.
  @spec workspace_stacks_read(Phoenix.LiveView.Socket.t(), term, term) ::
          Phoenix.LiveView.Socket.t()
  def workspace_stacks_read(socket, of, result) do
    if socket.assigns.workspace_stacks_of == of do
      stacks =
        case result do
          {:ok, names} -> names
          {:error, _reason} -> []
        end

      assign(socket, :workspace_stacks, stacks)
    else
      socket
    end
  end

  @doc false
  # choose_row/4 is a choice `value` of the Stack select of the destination `id`: A stack
  # of another repository… opens the destination's form; the workspace's harness or one of
  # its stacks saves at once; the saved stack closes the form. Nothing changes while a
  # save is in flight, so its answer reaches its destination.
  @spec choose_row(Phoenix.LiveView.Socket.t(), String.t(), String.t(), function) ::
          Phoenix.LiveView.Socket.t()
  def choose_row(socket, id, value, saved) do
    saving = match?(%{saving: true}, socket.assigns.target_edit)

    case Enum.find(socket.assigns.harness_targets, &(&1.id == id)) do
      _target when saving ->
        socket

      nil ->
        socket

      target when value == "other" ->
        socket |> cancel_async(:target_read) |> assign(:target_edit, new_edit(target, true))

      target ->
        socket = cancel_async(socket, :target_read)

        case row_choice(value) do
          nil -> assign(socket, :target_edit, nil)
          choice -> save_choice(socket, new_edit(target, false), choice, saved)
        end
    end
  end

  @doc false
  # cancel/1 closes the form of a destination, and cancels its read.
  @spec cancel(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def cancel(socket), do: socket |> cancel_async(:target_read) |> assign(:target_edit, nil)

  @doc false
  # pick/4 is the values of a destination's form sent: the stack and the version, then a
  # source chosen anew among the connected repositories and `assigned`, or an address
  # typed.
  @spec pick(Phoenix.LiveView.Socket.t(), map, map, [map]) :: Phoenix.LiveView.Socket.t()
  def pick(socket, edit, params, assigned) do
    edit = edit_values(edit, params)
    source_id = params["source"] || edit.source_id

    cond do
      source_id != edit.source_id ->
        pick_source(socket, edit, source_id, params["address"], assigned)

      source_id == "address" ->
        target_address(socket, edit, params["address"])

      true ->
        assign(socket, :target_edit, edit)
    end
  end

  @doc false
  # save/4 is Save of a destination's form: the choice its values come to
  # (`ApiaryWeb.HarnessComponents.target_choice/1`) saved, else the form as sent.
  @spec save(Phoenix.LiveView.Socket.t(), map, map, function) :: Phoenix.LiveView.Socket.t()
  def save(socket, edit, params, saved) do
    edit = edit_values(edit, params)

    case HarnessComponents.target_choice(edit) do
      nil -> assign(socket, :target_edit, edit)
      choice -> save_choice(socket, edit, choice, saved)
    end
  end

  @doc false
  # read_done/2 is the answer of the read of a destination's source, kept where that
  # source is still the one chosen: a connected repository's exported names, with the
  # stack set to one it exports; an assigned source's or an address's stacks; or why the
  # read failed.
  @spec read_done(Phoenix.LiveView.Socket.t(), {String.t(), String.t(), term}) ::
          Phoenix.LiveView.Socket.t()
  def read_done(socket, {id, git, result}) do
    case socket.assigns[:target_edit] do
      %{source: %{id: ^id, git: ^git} = source} = edit ->
        edit =
          case {source.kind, result} do
            {:linked, {:ok, names}} ->
              stack = HarnessComponents.with_stack(%{"stack" => edit.stack}, names)["stack"]
              %{edit | names: names, stack: stack, reading: false}

            {_kind, {:ok, stacks}} ->
              %{edit | stacks: stacks, reading: false}

            {_kind, {:error, reason}} ->
              %{edit | read_error: reason, reading: false}
          end

        assign(socket, :target_edit, edit)

      _other ->
        socket
    end
  end

  @doc false
  # read_failed/1 is a read of a destination's source whose task exited: `:exited`.
  @spec read_failed(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def read_failed(socket) do
    case socket.assigns[:target_edit] do
      %{reading: true} = edit ->
        assign(socket, :target_edit, %{edit | read_error: :exited, reading: false})

      _other ->
        socket
    end
  end

  @doc false
  # save_done/4 is the answer of a save that ran outside the page's process, given to
  # `saved` where the save is still in flight.
  @spec save_done(Phoenix.LiveView.Socket.t(), term, term, function) ::
          Phoenix.LiveView.Socket.t()
  def save_done(socket, choice, result, saved) do
    case socket.assigns[:target_edit] do
      %{saving: true} = edit ->
        socket |> assign(:target_edit, %{edit | saving: false}) |> saved.(choice, result)

      _other ->
        socket
    end
  end

  @doc false
  # save_failed/1 is a save outside the page's process that exited: nothing was changed.
  @spec save_failed(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def save_failed(socket) do
    case socket.assigns[:target_edit] do
      %{saving: true} = edit ->
        socket
        |> assign(:target_edit, %{edit | saving: false})
        |> put_flash(:error, gettext("Nothing was changed. Try again."))

      _other ->
        socket
    end
  end

  @doc false
  # refused/4 is a save of `choice` refused for `reason`, other than `:forbidden`: why,
  # under the destination, in the words of `ApiaryWeb.HarnessComponents.refusal_words/4`;
  # else "Nothing was changed. Try again." in a flash.
  @spec refused(Phoenix.LiveView.Socket.t(), term, term, String.t()) ::
          Phoenix.LiveView.Socket.t()
  def refused(%{assigns: %{target_edit: %{} = edit}} = socket, choice, reason, organisation) do
    {source, ref} =
      case choice do
        {:workspace, _stack} ->
          chosen = socket.assigns.chosen
          {HarnessComponents.exports_source(chosen), chosen.pin}

        choice ->
          HarnessComponents.refused(choice)
      end

    case HarnessComponents.refusal_words(reason, source, ref, organisation) do
      nil -> put_flash(socket, :error, gettext("Nothing was changed. Try again."))
      words -> assign(socket, :target_edit, %{edit | refusal: words})
    end
  end

  def refused(socket, _choice, _reason, _organisation),
    do: put_flash(socket, :error, gettext("Nothing was changed. Try again."))

  # The edit of `target`: its form of a stack of another repository where `open`, else a
  # save of its Stack select.
  defp new_edit(target, open) do
    %{
      id: target.id,
      target: target.target,
      open: open,
      source_id: "",
      address: "",
      address_error: nil,
      source: nil,
      stacks: nil,
      names: nil,
      reading: false,
      read_error: nil,
      stack: "",
      version: "branch",
      branch: "main",
      fixed: "",
      ref: "main",
      refusal: nil,
      saving: false
    }
  end

  # The choice of a destination's Stack select: the workspace's harness, or one of its
  # stacks; nil for the saved stack, which needs no save.
  defp row_choice("default"), do: :default
  defp row_choice("workspace:" <> stack) when stack != "", do: {:workspace, stack}
  defp row_choice(_value), do: nil

  defp edit_values(edit, params) do
    %{
      edit
      | stack: params["stack"] || edit.stack,
        version: params["version"] || edit.version,
        branch: params["branch"] || edit.branch,
        fixed: params["fixed"] || edit.fixed,
        ref: params["ref"] || edit.ref,
        refusal: nil
    }
  end

  defp pick_source(socket, edit, "address", text, _assigned) do
    edit = %{
      edit
      | source_id: "address",
        source: nil,
        stacks: nil,
        names: nil,
        read_error: nil,
        reading: false
    }

    socket |> cancel_async(:target_read) |> target_address(edit, text || edit.address)
  end

  defp pick_source(socket, edit, id, _text, assigned) do
    case Enum.find((socket.assigns.linked || []) ++ assigned, &(&1.id == id)) do
      nil ->
        socket
        |> cancel_async(:target_read)
        |> assign(:target_edit, %{
          edit
          | source_id: "",
            source: nil,
            stacks: nil,
            names: nil,
            read_error: nil,
            reading: false
        })

      source ->
        read_target(socket, edit, source)
    end
  end

  # The address typed, checked, and read when it passes; nothing is read again for the
  # same address.
  defp target_address(socket, edit, text) when is_binary(text) do
    cond do
      text == edit.address and edit.source != nil ->
        assign(socket, :target_edit, edit)

      String.trim(text) == "" ->
        socket
        |> cancel_async(:target_read)
        |> assign(:target_edit, %{
          edit
          | address: text,
            address_error: nil,
            source: nil,
            stacks: nil,
            read_error: nil,
            reading: false
        })

      true ->
        case Sources.address(text) do
          {:ok, source} ->
            read_target(socket, %{edit | address: text, address_error: nil}, source)

          {:error, error} ->
            socket
            |> cancel_async(:target_read)
            |> assign(:target_edit, %{
              edit
              | address: text,
                address_error: translate_error(error),
                source: nil,
                stacks: nil,
                read_error: nil,
                reading: false
            })
        end
    end
  end

  defp target_address(socket, edit, _text), do: assign(socket, :target_edit, edit)

  # `source` chosen: outside the page's process, the stacks a connected repository
  # exports (`Apiary.Stacks.Sources.exports/2`), else the stacks of an assigned source or
  # an address (`Apiary.Stacks.Sources.read/2`); a later choice cancels this read.
  defp read_target(socket, edit, source) do
    scope = socket.assigns.current_scope
    id = if source.kind == :address, do: "address", else: source.id

    read =
      if source.kind == :linked,
        do: fn -> {source.id, source.git, Sources.exports(scope, source)} end,
        else: fn -> {source.id, source.git, Sources.read(scope, source)} end

    socket
    |> assign(:target_edit, %{
      edit
      | source_id: id,
        source: source,
        stacks: nil,
        names: nil,
        stack: if(source.kind == :linked, do: "", else: "0"),
        read_error: nil,
        reading: true
    })
    |> cancel_async(:target_read)
    |> start_async(:target_read, read)
  end

  # The save of `choice` for the destination of `edit`: outside the page's process where
  # the save reads a harness repository, as a stack of the workspace's harness repository
  # does; else at once, its answer given to `saved`.
  defp save_choice(socket, edit, choice, saved) do
    scope = socket.assigns.current_scope

    if reads?(choice, socket.assigns.chosen) do
      target = edit.target

      socket
      |> assign(:target_edit, %{edit | saving: true})
      |> start_async(:target_save, fn ->
        {choice, Sources.choose_target(scope, target, choice)}
      end)
    else
      socket
      |> assign(:target_edit, edit)
      |> saved.(choice, Sources.choose_target(scope, edit.target, choice))
    end
  end

  defp reads?({:workspace, _stack}, %{choice: choice}), do: choice == :repository
  defp reads?(:default, _chosen), do: false
  defp reads?(_choice, _chosen), do: true
end

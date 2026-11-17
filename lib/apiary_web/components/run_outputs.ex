defmodule ApiaryWeb.RunOutputs do
  # The versions that one run pushed, each shown as its artifact page shows it
  # (`ApiaryWeb.ArtifactComponents.view/1`): a document as its text, a structured file as
  # its table of values, an image, a video or a file as that view does. A LiveComponent, so
  # it reads the files once for a run, not at every render of the page that has it:
  #
  #     <.live_component
  #       module={ApiaryWeb.RunOutputs}
  #       id="run-outputs"
  #       scope={@current_scope}
  #       number={@number}
  #       run_id={dispatch_run_id}
  #       heading={gettext("...")}
  #       skip={["some-type"]}
  #     />
  #
  # `scope` and `number` are the reader's scope and the number of the work item, which the
  # reader must be able to read (`work_item.read`); `run_id` is the id of the run in the
  # queue (`Apiary.Dispatches.DispatchRun`), the `run_id` of its versions. `skip` lists the
  # artifact types it leaves out, and `heading` is the heading it shows above the versions,
  # none where the run pushed none. Each version has its title as a link to its page.
  # Before the page connects, a document and a structured file show empty
  # (`ApiaryWeb.ArtifactLive.Load.content/3`). A version of a withdrawn name is left out.
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  use ApiaryWeb, :live_component

  alias Apiary.Artifacts
  alias ApiaryWeb.ArtifactComponents
  alias ApiaryWeb.ArtifactLive.Load

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    key = {assigns.number, assigns.run_id, connected?(socket)}

    if socket.assigns[:loaded] == key do
      {:ok, socket}
    else
      outputs =
        load(
          assigns.scope,
          assigns.number,
          assigns.run_id,
          Map.get(assigns, :skip, []),
          connected?(socket)
        )

      {:ok, assign(socket, loaded: key, outputs: outputs)}
    end
  end

  # Each version the run pushed, with its artifact, type and content, by artifact.
  defp load(scope, number, run_id, skip, connected?) do
    case Load.work_item(scope, number) do
      nil ->
        []

      work_item ->
        for artifact <- Artifacts.list(work_item),
            artifact.type not in skip,
            not Artifacts.withdrawn?(artifact),
            version <- artifact.versions,
            version.run_id == run_id do
          type = Load.type(work_item, artifact.type)
          content = if connected?, do: Load.content(type, version), else: :pending
          %{artifact: artifact, version: version, type: type, content: content}
        end
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :heading, fn -> nil end)

    ~H"""
    <div id={@id}>
      <section
        :if={@outputs != []}
        class="q-xp-sec"
        aria-labelledby={@heading && "#{@id}-h"}
      >
        <h3 :if={@heading} id={"#{@id}-h"}>{@heading}</h3>
        <div class="grid gap-6">
          <div
            :for={output <- @outputs}
            id={"#{@id}-#{output.version.public_id}"}
            class="grid gap-2"
          >
            <p class="font-medium break-all">
              <.link
                navigate={ArtifactComponents.version_path(@scope, @number, output.version.public_id)}
                class="q-link"
              >
                {ArtifactComponents.title(output.artifact, output.version)}
              </.link>
            </p>
            <ArtifactComponents.view
              id={"#{@id}-#{output.version.public_id}-view"}
              type={output.type}
              version={output.version}
              content={output.content}
              path={&ArtifactComponents.file_path(@scope, @number, output.version.public_id, &1)}
              script={~p"/assets/js/mermaid.js"}
            />
          </div>
        </div>
      </section>
    </div>
    """
  end
end

defmodule ApiaryWeb.TargetLive.FurtherRepositories do
  @moduledoc """
  The form page of what a target's runs also read, its further repositories
  (`/:org/:workspace/targets/tg_…/also-read`): a separate page, as every form is
  (`ApiaryWeb.PageComponents.page_form/1`), opened from Change on the target's Overview
  (`ApiaryWeb.TargetLive.Show`), with the `factory` feature: without it, or where it is
  hidden from the reader, the page is not found. It mounts on `work_item.read`, as the
  Backlog card of the Overview asks.

  One text area, one path a line, in the order the runs read them, its first field taking
  the focus. Save writes the whole list (`Apiary.Targets.set_further_repositories/3`) and
  goes back to the target's page with a flash; a refused list stays, its first broken
  rule under the field. Cancel goes back to the target's page.

  It opens for whoever may change the list (`target.set_further_repositories`, owners and
  admins) and is not found for anyone else, as an id of no target of the workspace is. It
  is not found either in a workspace whose domain has no label for a run's paths
  (`Apiary.Lingo.Domain.paths_label/1`), whose runs read no further paths.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory
  on_mount {ApiaryWeb.Access, :"work_item.read"}

  import ApiaryWeb.TargetComponents

  alias Apiary.{Access, Targets}
  alias Apiary.Lingo.Domain
  alias Apiary.Runs.Target

  @action :"target.set_further_repositories"

  @impl true
  def mount(%{"target_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with true <- Domain.paths_label(scope.workspace) != nil,
         %Target{} = target <- Targets.get_by_public_id(scope, public_id),
         true <- Access.can?(scope, @action, target) do
      shared = Targets.shared?(scope, target.path)

      {:ok,
       socket
       |> assign(
         target: target,
         shared: shared,
         page_title: title(target, shared)
       )
       |> assign_form(Enum.join(Targets.further_repositories(target), "\n"), [])}
    else
      _not_found -> raise ApiaryWeb.NotFound
    end
  end

  @impl true
  def handle_event("save", %{"target" => %{"further_repositories" => text}}, socket)
      when is_binary(text) do
    %{current_scope: scope, target: target, shared: shared} = socket.assigns

    case Targets.set_further_repositories(scope, target, text) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_words(saved, shared))
         |> push_navigate(to: target_path(scope, saved))}

      {:error, %Ecto.Changeset{errors: errors}} ->
        {:noreply, assign_form(socket, text, errors)}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           ApiaryWeb.Access.who_may(
             scope,
             @action,
             gettext("Only owners and admins change this.")
           )
         )}

      {:error, :not_found} ->
        {:noreply, push_navigate(socket, to: target_path(scope, target))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp assign_form(socket, text, errors),
    do:
      assign(
        socket,
        :form,
        to_form(%{"further_repositories" => text}, as: :target, errors: errors)
      )

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, owner: owner(assigns.target), name: name(assigns.target, assigns.shared))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:targets}
      target={@target.id}
      width="read"
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/targets"}>
        {gettext("Targets")}
      </:crumb>
      <:crumb navigate={target_path(@current_scope, @target)}>
        <.target_name path={@target.path} system={@target.system} shared={@shared} />
      </:crumb>
      <:crumb>{gettext("Change what its runs read")}</:crumb>

      <.page_form id="further-repositories-page" title={title(@target, @shared)}>
        <:description>
          {gettext("A run of %{target} also reads these targets of %{owner}, in this order.",
            target: @name,
            owner: @owner
          )}
        </:description>
        <.form for={@form} id="further-repositories-form" phx-submit="save" novalidate>
          <div class="grid gap-4">
            <div class="grid gap-1">
              <.input
                field={@form[:further_repositories]}
                type="textarea"
                label={gettext("Targets")}
                hint={
                  gettext("One per line, such as %{owner}/docs: targets of %{owner} only, each once.",
                    owner: @owner
                  )
                }
                rows="6"
                autocomplete="off"
                spellcheck="false"
                class="font-mono"
                aria-describedby="further-repositories-limit"
                phx-mounted={JS.focus()}
              />
              <p id="further-repositories-limit" class="text-[12.5px]/[18px] text-muted">
                {gettext("Together with %{target}, at most 256 characters.",
                  target: Apiary.ExternalText.sent(@target.path)
                )}
              </p>
            </div>
            <.page_form_foot
              id="further-repositories-save"
              cancel={target_path(@current_scope, @target)}
            >
              <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
                {gettext("Save")}
              </.button>
            </.page_form_foot>
          </div>
        </.form>
      </.page_form>
    </Layouts.app>
    """
  end

  defp title(target, shared),
    do: gettext("Change what runs of %{target} read", target: name(target, shared))

  defp saved_words(%Target{further_repositories: []} = target, shared),
    do: gettext("Runs of %{target} now read no other target.", target: name(target, shared))

  defp saved_words(%Target{further_repositories: paths} = target, shared),
    do:
      ngettext(
        "%{target} now also reads %{count} target.",
        "%{target} now also reads %{count} targets.",
        length(paths),
        target: name(target, shared)
      )

  # The target in words, in its notation: its system only where its path is shared.
  defp name(target, shared), do: target_label(target.system, target.path, shared)

  # The target's owner, the first segment of its path, which every path it also reads has.
  defp owner(%Target{path: path}), do: path |> String.split("/") |> hd()
end

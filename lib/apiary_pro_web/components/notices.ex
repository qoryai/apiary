defmodule ApiaryProWeb.Notices do
  @moduledoc """
  The edition's notices at the top of an organisation's pages, rendered in the core's `:notices`
  slot (`ApiaryWeb.Extension`), which the core's layout puts above the page
  (`ApiaryWeb.Layouts.app/1`). Each is the core's `notice/1`; together they are one stack,
  `#organisation-notices`, 80 characters wide at most, as the notices of the core's lists,
  and nothing at all when none applies:

  - that a reader, who reads it with no membership there (`Apiary.Access.reader/1`),
    reads everything and changes nothing: a person of a client's operator, or else an
    admin of this Qory Apiary, who reads every other organisation on it. A person who
    is both reads a client as its operator's (`ApiaryPro.Reach.reach/1`), and is told so
    alone;
  - that the organisation is suspended, read-only for everyone in it
    (`ApiaryPro.Access.suspended?/1`), or else that no owner of it may act because of a
    suspension (`ApiaryPro.Reach.owner_suspended?/1`), so that it runs below the owner
    level;
  - that the instance's admins offer the reader the ownership of the organisation, while
    no owner of it may act, with the way to the offer
    (`ApiaryProWeb.SettingsLive.Ownership`). The navigation's counts carry the offer
    (`c:ApiaryWeb.Edition.nav_counts/1`), read when the page mounts and when the reader's
    membership changes, not on every render.
  """
  use ApiaryProWeb, :html

  @doc """
  notices/1 renders the edition's notices for the organisation of `scope`, or nothing: the
  reader's, for a person of a client's operator or an instance admin who reads it; what a
  suspension means for it; and the offer of its ownership, for the admin it is offered to (`counts`'
  `ownership_offer`).
  """
  attr :scope, :any, required: true
  attr :organisation, :any, required: true
  attr :counts, :map, default: nil

  @spec notices(map) :: Phoenix.LiveView.Rendered.t()
  def notices(assigns) do
    # While the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`), an
    # owner or an admin of a client's operator with no membership in the client works
    # in it at that level: the notice says so. They are no reader (`Apiary.Access.reader/1`
    # is nil for a role that changes something), so the reader's notice goes to the
    # operator's members alone.
    assigns =
      assigns
      |> assign(:reader, Apiary.Access.reader(assigns.scope))
      |> assign(:operator_owner, operator_owner(assigns.scope))
      |> assign(:suspended, ApiaryPro.Access.suspended?(assigns.scope))
      |> assign(:owner_suspended, ApiaryPro.Reach.owner_suspended?(assigns.organisation))
      |> assign(:offered, ownership_offered?(assigns.counts))

    ~H"""
    <div
      :if={
        @reader in [:operator, :instance] or @operator_owner != nil or @suspended or
          @owner_suspended or @offered
      }
      id="organisation-notices"
      class="grid max-w-[80ch] gap-2"
    >
      <div :if={@reader == :operator} id="operator-reader">
        <.notice>
          {operator_reader_sentence(@scope, @organisation)}
        </.notice>
      </div>
      <div :if={@operator_owner} id="operator-owner">
        <.notice>
          {operator_owner_sentence(@operator_owner, @organisation)}
        </.notice>
      </div>
      <div :if={@reader == :instance} id="instance-reader">
        <.notice>
          {gettext(
            "You read %{organisation} as support: everything here can be read, and nothing changed.",
            organisation: @organisation.name
          )}
        </.notice>
      </div>
      <div :if={@suspended} id="organisation-suspended">
        <.notice kind={:warning}>
          <.rich text={
            rich_gettext(
              "%{organisation} is suspended: everything in it can be read, nothing can be changed, and its access keys are refused. %{contact_support}.",
              organisation: @organisation.name,
              contact_support: ApiaryWeb.Support.rich()
            )
          } />
        </.notice>
      </div>
      <div :if={not @suspended and @owner_suspended} id="owner-suspended">
        <.notice kind={:warning}>
          <.rich text={
            rich_gettext(
              "Every owner of %{organisation} is suspended. Its admins and members keep working and its runs continue; what only an owner does, such as deleting or transferring it and changing locked rules, waits until support acts. %{contact_support}.",
              organisation: @organisation.name,
              contact_support: ApiaryWeb.Support.rich()
            )
          } />
        </.notice>
      </div>
      <div :if={@offered} id="ownership-offer-notice">
        <.notice kind={:info}>
          <.rich text={
            rich_gettext(
              "Support offers you the ownership of %{name}: %{link}.",
              name: @organisation.name,
              link: {:link, ~p"/#{@organisation}/settings/ownership", gettext("see the offer")}
            )
          } />
        </.notice>
      </div>
    </div>
    """
  end

  defp ownership_offered?(%{ownership_offer: true}), do: true
  defp ownership_offered?(_counts), do: false

  # `{level, operator's name}` for an owner or an admin of the client's operator with no
  # membership in it, while the flag is on; nil otherwise.
  defp operator_owner(%Apiary.Accounts.Scope{membership: nil} = scope) do
    with true <- ApiaryPro.Flags.operator_infrastructure?(),
         level when level in [:owner, :admin] <- ApiaryPro.Reach.operator_level(scope),
         name when is_binary(name) <- ApiaryProWeb.Readers.operator_name(scope) do
      {level, name}
    else
      _ -> nil
    end
  end

  defp operator_owner(_scope), do: nil

  defp operator_owner_sentence({:owner, operator}, organisation) do
    gettext("You work in %{organisation} as an owner of %{operator}, its operator.",
      organisation: organisation.name,
      operator: operator
    )
  end

  defp operator_owner_sentence({:admin, operator}, organisation) do
    gettext("You work in %{organisation} as an admin of %{operator}, its operator.",
      organisation: organisation.name,
      operator: operator
    )
  end

  defp operator_reader_sentence(scope, organisation) do
    case ApiaryProWeb.Readers.operator_name(scope) do
      nil ->
        gettext(
          "You read %{organisation} as a person of its operator: everything here can be read, and nothing changed.",
          organisation: organisation.name
        )

      operator ->
        gettext(
          "You read %{organisation} as a person of %{operator}, its operator: everything here can be read, and nothing changed.",
          organisation: organisation.name,
          operator: operator
        )
    end
  end
end

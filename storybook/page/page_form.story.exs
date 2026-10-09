defmodule ApiaryWeb.Storybook.Page.PageForm do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &ApiaryWeb.PageComponents.page_form/1

  def imports,
    do: [
      {ApiaryWeb.CoreComponents, icon: 1, button: 1, input: 1},
      {ApiaryWeb.PageComponents, page_form_foot: 1}
    ]

  def container, do: {:div, class: "w-full p-6"}

  def variations do
    [
      %Variation{
        id: :new_node,
        description:
          "A create form as a page of its own, never a dialog: Cancel, at its foot, and " <>
            "the breadcrumb lead to where it was opened from.",
        attributes: %{id: "new-node", title: "New node"},
        slots: [
          ~s|<:description>A machine that runs runs, one at a time.</:description>|,
          ~s|<form class="grid gap-4" novalidate><.input name="name" value="build-01" label="Name" /><.page_form_foot id="new-node-save" cancel="#" cancel_by="href"><.button variant="primary" type="button">Create node</.button><:note>Owners and admins make nodes.</:note></.page_form_foot></form>|
        ]
      }
    ]
  end
end

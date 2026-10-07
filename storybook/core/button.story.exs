defmodule ApiaryWeb.Storybook.Core.Button do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &ApiaryWeb.CoreComponents.button/1
  def imports, do: [{ApiaryWeb.CoreComponents, icon: 1}]
  def container, do: {:div, class: "flex w-full flex-wrap items-center gap-3 p-3"}

  def variations do
    [
      %VariationGroup{
        id: :variants,
        description: "Every variant, at the default size, sm.",
        variations:
          for {variant, words} <- [
                {"primary", "Save"},
                {"default", "Cancel"},
                {"ghost", "Show all"},
                {"danger", "Revoke key"},
                {"danger-ghost", "Remove"},
                {"link", "Retire previous secret"}
              ] do
            %Variation{
              id: String.to_atom(String.replace(variant, "-", "_")),
              attributes: %{variant: variant},
              slots: [words]
            }
          end
      },
      %VariationGroup{
        id: :sizes,
        variations:
          for size <- ~w(xs sm md) do
            %Variation{id: String.to_atom(size), attributes: %{size: size}, slots: ["Add rule"]}
          end
      },
      %VariationGroup{
        id: :with_an_icon,
        description: "A glyph before the words, faint, as a list's bar draws Add rule.",
        variations: [
          %Variation{
            id: :add_rule,
            slots: [~s|<.icon name="hero-plus-micro" class="size-4 text-faint" />Add rule|]
          },
          %Variation{
            id: :new_node,
            attributes: %{variant: "primary"},
            slots: [~s|<.icon name="hero-plus-micro" class="size-4" />New node|]
          }
        ]
      },
      %VariationGroup{
        id: :states,
        description: "Disabled; a link styled as a button; with the words its busy state says.",
        variations: [
          %Variation{
            id: :disabled,
            attributes: %{variant: "primary", disabled: true},
            slots: ["Save"]
          },
          %Variation{id: :as_a_link, attributes: %{navigate: "/acme/shop"}, slots: ["Back"]},
          %Variation{
            id: :loading_text,
            attributes: %{variant: "primary", loading_text: "Saving"},
            slots: ["Save"]
          }
        ]
      }
    ]
  end
end

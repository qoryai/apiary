defmodule ApiaryWeb.Storybook.Core.Choice do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &ApiaryWeb.CoreComponents.input/1
  def imports, do: [{ApiaryWeb.CoreComponents, icon: 1}]
  def container, do: {:div, class: "w-full max-w-[480px] p-3"}

  @types [
    %{
      value: "software",
      title: "Software",
      subtitle: "For work on code. Each ticket needs a repository."
    },
    %{
      value: "general",
      title: "General",
      subtitle: "For any other work, such as marketing, incidents or customer care."
    }
  ]

  @models [
    %{value: "opus-5-5", title: "Claude Opus 5.5", subtitle: "claude-opus-5-5", mono: :subtitle},
    %{value: "opus-5", title: "Claude Opus 5", subtitle: "claude-opus-5", mono: :subtitle},
    %{value: "sonnet-5", title: "Claude Sonnet 5", subtitle: "claude-sonnet-5", mono: :subtitle},
    %{
      value: "sonnet-4-6",
      title: "Claude Sonnet 4.6",
      subtitle: "claude-sonnet-4-6",
      mono: :subtitle
    },
    %{
      value: "haiku-4-5",
      title: "Claude Haiku 4.5",
      subtitle: "claude-haiku-4-5",
      mono: :subtitle
    },
    %{value: "opus-4-8", title: "Claude Opus 4.8", subtitle: "claude-opus-4-8", mono: :subtitle},
    %{value: "opus-4-7", title: "Claude Opus 4.7", subtitle: "claude-opus-4-7", mono: :subtitle},
    %{value: "opus-4-6", title: "Claude Opus 4.6", subtitle: "claude-opus-4-6", mono: :subtitle},
    %{
      value: "other",
      title: "Another model",
      subtitle: "A model id this list leaves out.",
      keep: true
    }
  ]

  def variations do
    [
      %Variation{
        id: :prompt,
        description:
          "Nothing chosen: the button shows the prompt. The storybook runs no hook, so the " <>
            "panel stays closed.",
        attributes: %{
          type: "choice",
          id: "workspace_domain",
          name: "workspace[domain]",
          value: nil,
          label: "Type",
          prompt: "Choose a type",
          options: @types,
          hint: "You can't change the type after you create the workspace."
        }
      },
      %Variation{
        id: :chosen,
        description: "An option chosen: its title and subtitle on the button.",
        attributes: %{
          type: "choice",
          id: "model_choice_model",
          name: "model_choice[model]",
          value: "opus-5-5",
          label: "Model",
          options: @models
        }
      },
      %Variation{
        id: :error,
        description: "An error in place of the hint, tied to the button.",
        attributes: %{
          type: "choice",
          id: "workspace_type",
          name: "workspace[type]",
          value: nil,
          label: "Type",
          prompt: "Choose a type",
          options: @types,
          errors: ["Choose a type."]
        }
      }
    ]
  end
end

defmodule Apiary.Harnesses.QoryCopy.Texts do
  # Written by `mix apiary.harness.update` from the templates' `process.yaml` in
  # priv/harness/qory/; edit the task, not this file. The texts are in the
  # `workspace type` context, so that `mix gettext.extract` keeps them.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  @doc false
  # texts/1 is the name, summary and description of the template in the module
  # `template` of the Qory harness, translated in the locale of the caller's process;
  # nil for a module that is no template.
  @spec texts(String.t()) ::
          %{name: String.t(), summary: String.t(), description: String.t()} | nil
  def texts("software-factory"),
    do: %{
      name: pgettext("workspace type", "Software factory"),
      summary:
        pgettext(
          "workspace type",
          "Agents change code in your repositories. Each ticket needs a repository."
        ),
      description:
        pgettext(
          "workspace type",
          "Each ticket comes from a work source, such as an issue tracker. Agents take the ticket through the stages, and at the end of each stage a member approves the result before the next stage starts. Changes go to your repositories through the destination you connect.\n\nYou connect: where work comes from, where changes go, and a model."
        )
    }

  def texts(_template), do: nil
end

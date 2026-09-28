defmodule ApiaryWeb.DocsHTML do
  @moduledoc "The page `ApiaryWeb.DocsController` shows when the documentation is not built."
  use ApiaryWeb, :html

  embed_templates "docs_html/*"
end

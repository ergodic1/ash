defmodule Ash.Resource.Relationships.HasOne do
  @moduledoc "Represents a has_one relationship on a resource"

  defstruct [
    :name,
    :source,
    :destination,
    :destination_field,
    :private?,
    :source_field,
    :allow_orphans?,
    :writable?,
    :context,
    :description,
    :filter,
    :sort,
    :read_action,
    :not_found_message,
    :violation_message,
    validate_destination_field?: true,
    cardinality: :one,
    type: :has_one,
    required?: false
  ]

  @type t :: %__MODULE__{
          type: :has_one,
          cardinality: :one,
          source: Ash.Resource.t(),
          writable?: boolean,
          name: atom,
          read_action: atom,
          type: Ash.Type.t(),
          filter: Ash.Filter.t(),
          destination: Ash.Resource.t(),
          destination_field: atom,
          private?: boolean,
          source_field: atom,
          allow_orphans?: boolean,
          description: String.t()
        }

  import Ash.Resource.Relationships.SharedOptions
  alias Ash.OptionsHelpers

  @global_opts shared_options()
               |> OptionsHelpers.set_default!(:source_field, :id)

  @opt_schema Ash.OptionsHelpers.merge_schemas(
                [
                  required?: [
                    type: :boolean,
                    doc: """
                    Marks the relationship as required. This is *not* currently validated anywhere, since the
                    relationship is managed by the destination, but ash_graphql uses it for type information,
                    and it can be used for expressiveness.
                    """
                  ]
                ],
                @global_opts,
                "Relationship Options"
              )

  @doc false
  def opt_schema, do: @opt_schema
end

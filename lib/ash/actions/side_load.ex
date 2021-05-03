defmodule Ash.Actions.SideLoad do
  @moduledoc false

  alias Ash.Engine
  alias Ash.Engine.Request

  require Ash.Query

  def requests(
        query,
        pagination_map,
        root_query \\ nil,
        path \\ [],
        tenant \\ nil
      )

  def requests(nil, _, _, _, _), do: {nil, []}
  def requests(%{side_load: []} = query, _, _, _, _), do: {query, []}

  def requests(
        %{side_load: side_loads} = query,
        pagination_map,
        root_query,
        path,
        tenant
      ) do
    root_query = root_query || query
    tenant = tenant || query.tenant || root_query.tenant

    side_loads
    |> List.wrap()
    |> Enum.reduce({query, []}, fn {relationship, further}, {query, requests} ->
      relationship = Ash.Resource.Info.relationship(query.resource, relationship)

      related_query =
        case further do
          %Ash.Query{} = query ->
            Ash.Query.set_api(query, root_query.api)

          further ->
            relationship.destination
            |> Ash.Query.new(root_query.api)
            |> Ash.Query.load(further)
        end

      related_query =
        if tenant && !related_query.tenant do
          Ash.Query.set_tenant(related_query, tenant)
        else
          related_query
        end
        |> maybe_select(relationship.destination_field)

      new_path = [relationship | path]

      {related_query, further_requests} =
        requests(
          related_query,
          pagination_map,
          root_query,
          new_path,
          related_query.tenant
        )

      {
        maybe_select(query, relationship.source_field),
        requests ++
          further_requests ++
          do_requests(
            relationship,
            related_query,
            path,
            root_query,
            pagination_map
          )
      }
    end)
  end

  defp maybe_select(query, field) do
    if query.select do
      Ash.Query.select(query, [field])
    else
      query
    end
  end

  def attach_side_loads([%resource{} | _] = data, %{side_load: side_loads}) do
    side_loads
    |> Enum.sort_by(fn {key, _value} ->
      last_relationship = last_relationship!(resource, key)
      # We want to do `many_to_many` last, so we know we've
      # done their join assocs first. Pretty hacky
      {length(key), last_relationship.type == :many_to_many}
    end)
    |> Enum.reduce(data, fn {key, value}, data ->
      last_relationship = last_relationship!(resource, key)
      lead_path = :lists.droplast(key)

      {value, page} = unpaginate(value)

      case last_relationship do
        %{type: :many_to_many} ->
          attach_many_to_many_side_loads(
            data,
            lead_path,
            last_relationship,
            side_loads,
            value,
            page
          )

        %{cardinality: :many} ->
          attach_to_many_side_loads(value, last_relationship, data, lead_path, page)

        %{cardinality: :one} ->
          attach_to_one_side_loads(value, last_relationship, data, lead_path, page)
      end
    end)
  end

  def attach_side_loads(data, state) when not is_list(data) do
    [data]
    |> attach_side_loads(state)
    |> List.first()
  end

  def attach_side_loads(data, _) do
    data
  end

  defp unpaginate(%struct{results: results} = page)
       when struct in [Ash.Page.Keyset, Ash.Page.Offset] do
    {results, %{page | results: []}}
  end

  defp unpaginate(results) do
    {results, nil}
  end

  defp repaginate(results, nil) do
    results
  end

  defp repaginate(results, page) do
    %{page | results: List.wrap(results)}
  end

  defp attach_to_many_side_loads(value, last_relationship, data, lead_path, page) do
    values = Enum.group_by(value, &Map.get(&1, last_relationship.destination_field))

    map_or_update(data, lead_path, fn record ->
      source_key = Map.get(record, last_relationship.source_field)
      related_records = Map.get(values, source_key, [])
      Map.put(record, last_relationship.name, repaginate(related_records, page))
    end)
  end

  defp attach_to_one_side_loads(value, last_relationship, data, lead_path, page) do
    values =
      Enum.into(value, %{}, fn item ->
        {Map.get(item, last_relationship.destination_field), item}
      end)

    map_or_update(data, lead_path, fn record ->
      source_key = Map.get(record, last_relationship.source_field)
      related_record = Map.get(values, source_key)
      Map.put(record, last_relationship.name, repaginate(related_record, page))
    end)
  end

  defp attach_many_to_many_side_loads(data, lead_path, last_relationship, side_loads, value, page) do
    join_path = lead_path ++ [last_relationship.join_relationship]

    join_data =
      side_loads
      |> Map.get(join_path, [])

    map_or_update(data, lead_path, fn record ->
      source_value = Map.get(record, last_relationship.source_field)

      join_values =
        join_data
        |> Enum.filter(fn join_row ->
          Map.get(join_row, last_relationship.source_field_on_join_table) ==
            source_value
        end)
        |> Enum.map(&Map.get(&1, last_relationship.destination_field_on_join_table))

      related_records =
        value
        |> Enum.filter(fn value ->
          destination_value = Map.get(value, last_relationship.destination_field)

          destination_value in join_values
        end)

      Map.put(record, last_relationship.name, repaginate(related_records, page))
    end)
  end

  defp map_or_update(nil, _, _), do: nil

  defp map_or_update(%struct{results: results} = page, path, func)
       when struct in [Ash.Page.Offset, Ash.Page.Keyset] do
    %{page | results: map_or_update(results, path, func)}
  end

  defp map_or_update(record, [], func) when not is_list(record), do: func.(record)

  defp map_or_update(records, [], func) do
    Enum.map(records, fn record ->
      if record do
        func.(record)
      else
        nil
      end
    end)
  end

  defp map_or_update(records, [path | tail], func) do
    map_or_update(records, [], fn record ->
      Map.update!(record, path, &map_or_update(&1, tail, func))
    end)
  end

  defp last_relationship!(resource, [last]) do
    Ash.Resource.Info.relationship(resource, last) || raise "Assumption Failed"
  end

  defp last_relationship!(resource, [first | rest]) do
    relationship = Ash.Resource.Info.relationship(resource, first) || raise "Assumption Failed"

    last_relationship!(relationship.destination, rest)
  end

  defp do_requests(relationship, related_query, path, root_query, pagination_map) do
    side_load_request =
      side_load_request(
        relationship,
        related_query,
        root_query,
        path,
        pagination_map
      )

    case relationship.type do
      :many_to_many ->
        case join_assoc_request(
               relationship,
               related_query,
               root_query,
               path
             ) do
          nil ->
            [side_load_request]

          request ->
            [side_load_request, request]
        end

      _ ->
        [side_load_request]
    end
  end

  defp side_load_request(
         relationship,
         related_query,
         root_query,
         path,
         pagination_map
       ) do
    relationship_path = Enum.reverse(Enum.map([relationship | path], &Map.get(&1, :name)))

    request_path = [
      :side_load,
      relationship_path
    ]

    dependencies =
      case path do
        [] ->
          [request_path ++ [:authorization_filter]]

        dependent_path ->
          [
            request_path ++ [:authorization_filter],
            [:side_load, Enum.reverse(Enum.map(dependent_path, &Map.get(&1, :name))), :data]
          ]
      end

    dependencies = [[:data, :data] | dependencies]

    pagination_options = pagination_map[relationship_path]

    dependencies =
      if relationship.type == :many_to_many &&
           !lateral_join?(related_query, relationship, pagination_options) do
        join_relationship = join_relationship(relationship)

        join_relationship_path =
          Enum.map(join_relationship_path(path, join_relationship), & &1.name)

        [
          [
            :side_load,
            join_relationship_path,
            :data
          ]
          | dependencies
        ]
      else
        dependencies
      end

    source =
      [relationship | path]
      |> Enum.reverse()
      |> Enum.map_join(".", &Map.get(&1, :name))

    Engine.Request.new(
      action: Ash.Resource.Info.primary_action(relationship.destination, :read),
      resource: relationship.destination,
      name: "side_load #{source}",
      api: related_query.api,
      path: request_path,
      query:
        side_load_query(
          relationship,
          related_query,
          path,
          root_query
        ),
      data:
        Request.resolve(dependencies, fn data ->
          base_query =
            case get_in(data, request_path ++ [:authorization_filter]) do
              nil ->
                related_query

              authorization_filter ->
                Ash.Query.filter(related_query, ^authorization_filter)
            end

          with {:ok, new_query} <-
                 true_side_load_query(
                   relationship,
                   base_query,
                   data,
                   path,
                   pagination_options
                 ),
               {:ok, results} <-
                 run_actual_query(
                   new_query,
                   data,
                   path,
                   relationship,
                   pagination_options
                 ) do
            {:ok, results}
          else
            :nothing ->
              {:ok, []}

            {:error, error} ->
              {:error, error}
          end
        end)
    )
  end

  defp join_relationship(relationship) do
    Ash.Resource.Info.relationship(relationship.source, relationship.join_relationship)
  end

  defp join_relationship_path(path, join_relationship) do
    Enum.reverse([join_relationship | path])
  end

  defp join_assoc_request(
         relationship,
         related_query,
         root_query,
         path
       ) do
    join_relationship = join_relationship(relationship)
    join_relationship_name = join_relationship.name

    case path do
      [%{name: ^join_relationship_name} | _] ->
        nil

      path ->
        join_relationship_path = join_relationship_path(path, join_relationship)
        join_relationship_path_names = Enum.map(join_relationship_path, & &1.name)

        dependencies =
          if path == [] do
            [[:side_load, join_relationship_path_names, :authorization_filter]]
          else
            [
              [:side_load, join_relationship_path_names, :authorization_filter],
              [:side_load, Enum.reverse(Enum.map(path, &Map.get(&1, :name))), :data]
            ]
          end

        lateral_join? = lateral_join?(related_query, relationship, nil)

        dependencies =
          if lateral_join? do
            dependencies ++
              [
                [
                  :side_load,
                  Enum.reverse(Enum.map(path, &Map.get(&1, :name))) ++ [relationship.name],
                  :data
                ]
              ]
          else
            dependencies
          end

        dependencies = [[:data, :data] | dependencies]

        related_query =
          if related_query.tenant do
            join_relationship.destination
            |> Ash.Query.new(related_query.api)
            |> Ash.Query.set_tenant(related_query.tenant)
          else
            Ash.Query.new(join_relationship.destination, related_query.api)
          end

        Request.new(
          action: Ash.Resource.Info.primary_action(relationship.destination, :read),
          resource: relationship.through,
          name: "side_load join #{join_relationship.name}",
          api: related_query.api,
          path: [:side_load, join_relationship_path_names],
          query:
            side_load_query(
              join_relationship,
              related_query,
              Enum.reverse(join_relationship_path),
              root_query
            ),
          data:
            Request.resolve(dependencies, fn
              data ->
                base_query =
                  case get_in(data, [
                         :side_load,
                         join_relationship_path_names,
                         :authorization_filter
                       ]) do
                    nil ->
                      related_query

                    authorization_filter ->
                      Ash.Query.filter(related_query, ^authorization_filter)
                  end

                base_query =
                  if related_query.tenant do
                    Ash.Query.set_tenant(base_query, related_query.tenant)
                  else
                    base_query
                  end

                with {:ok, new_query} <-
                       true_side_load_query(
                         join_relationship,
                         base_query,
                         data,
                         path,
                         nil
                       ),
                     new_query <-
                       add_join_destination_filter(
                         new_query,
                         lateral_join?,
                         data,
                         relationship,
                         Enum.reverse(Enum.map(path, &Map.get(&1, :name))) ++ [relationship.name]
                       ),
                     {:ok, results} <-
                       run_actual_query(
                         new_query,
                         data,
                         path,
                         join_relationship
                       ) do
                  {:ok, results}
                else
                  :nothing ->
                    {:ok, []}

                  {:error, error} ->
                    {:error, error}
                end
            end)
        )
    end
  end

  defp add_join_destination_filter(query, true, data, relationship, destination_path) do
    ids =
      data
      |> get_in([
        :side_load,
        destination_path,
        :data
      ])
      |> case do
        %page{results: results} when page in [Ash.Page.Keyset, Ash.Page.Offset] ->
          results

        data ->
          data
      end
      |> List.wrap()
      |> Enum.map(fn related ->
        Map.get(related, relationship.destination_field)
      end)

    filter = [{relationship.destination_field_on_join_table, [{:in, ids}]}]

    Ash.Query.filter(query, ^filter)
  end

  defp add_join_destination_filter(query, false, _, _, _) do
    query
  end

  defp lateral_join?(query, relationship, pagination_options) do
    {offset, limit} = offset_and_limit(query, relationship, pagination_options)

    resources =
      [relationship.source, Map.get(relationship, :through), relationship.destination]
      |> Enum.reject(&is_nil/1)

    (limit || offset) &&
      Ash.DataLayer.data_layer_can?(
        relationship.source,
        {:lateral_join, resources}
      )
  end

  defp run_actual_query(query, data, path, relationship, pagination_options \\ nil) do
    {offset, limit} = offset_and_limit(query, relationship, pagination_options)

    source_data =
      case path do
        [] ->
          get_in(data, [:data, :data])

        path ->
          data
          |> Map.get(:side_load, %{})
          |> Map.get(path, %{})
          |> Map.get(:data, [])
      end

    cond do
      lateral_join?(query, relationship, pagination_options) && relationship.type != :many_to_many ->
        query
        |> Ash.Query.set_context(%{
          data_layer: %{
            lateral_join_source:
              {source_data,
               [
                 {relationship.source, relationship.source_field, relationship.destination_field,
                  relationship}
               ]}
          }
        })
        |> Ash.Query.set_context(relationship.context)
        |> Ash.Query.do_filter(relationship.filter)
        |> remove_relationships_from_load()
        |> read(relationship.read_action, pagination_options)

      lateral_join?(query, relationship, pagination_options) ->
        join_relationship =
          Ash.Resource.Info.relationship(relationship.source, relationship.join_relationship)

        query
        |> Ash.Query.set_context(%{
          data_layer: %{
            lateral_join_source: {
              source_data,
              [
                {relationship.source, relationship.source_field,
                 relationship.source_field_on_join_table, relationship},
                {relationship.through, relationship.destination_field_on_join_table,
                 relationship.destination_field, join_relationship}
              ]
            }
          }
        })
        |> Ash.Query.set_context(relationship.context)
        |> Ash.Query.do_filter(relationship.filter)
        |> remove_relationships_from_load()
        |> read(relationship.read_action, pagination_options)

      limit || offset ->
        artificial_limit_and_offset(query, limit, offset, relationship, pagination_options)

      true ->
        query
        |> Ash.Query.set_context(relationship.context)
        |> Ash.Query.do_filter(relationship.filter)
        |> remove_relationships_from_load()
        |> read(relationship.read_action, pagination_options)
    end
  end

  defp offset_and_limit(query, relationship, pagination_options) do
    action =
      if relationship.read_action do
        Ash.Resource.Info.action(query.resource, relationship.read_action)
      else
        primary_read(query)
      end

    if pagination_options do
      page_opts = Ash.Actions.Read.page_opts(action, page: pagination_options)

      offset = (query.offset || 0) + (page_opts[:offset] || 0)

      offset =
        if offset == 0 do
          nil
        else
          offset
        end

      limit =
        if page_opts[:limit] && query.limit do
          min(page_opts[:limit], query.limit)
        else
          page_opts[:limit] || query.limit
        end

      {offset, limit}
    else
      if query.offset == 0 do
        {nil, query.limit}
      else
        {query.offset, query.limit}
      end
    end
  end

  defp artificial_limit_and_offset(query, limit, offset, relationship, pagination_options) do
    quercy
    |> Ash.Query.set_context(relationship.context)
    |> Ash.Query.do_filter(relationship.filter)
    |> remove_relationships_from_load()
    |> read(relationship.read_action, false)
    |> case do
      {:ok, results} ->
        new_results =
          results
          |> Enum.group_by(fn record ->
            Map.get(record, relationship.destination_field)
          end)
          |> Enum.flat_map(fn {_, group} ->
            offset_records = Enum.drop(group, offset || 0)

            if limit do
              Enum.take(offset_records, limit)
            else
              offset_records
            end
          end)

        {:ok, new_results}

      {:error, error} ->
        {:error, error}
    end
  end

  defp read(query, action, pagination_options) do
    action = action || primary_read(query)

    if pagination_options do
      Ash.Actions.Read.run(query, action, page: pagination_options)
    else
      Ash.Actions.Read.unpaginated_read(query, action)
    end
  end

  defp primary_read(query) do
    action = Ash.Resource.Info.primary_action(query.resource, :read)

    if action do
      action
    else
      raise """
      No read action for loaded resource: #{query.resource}
      """
    end
  end

  defp remove_relationships_from_load(query) do
    case query.side_load do
      empty when empty in [nil, []] ->
        query

      load ->
        new_load =
          load
          |> List.wrap()
          |> Enum.reject(fn
            item when is_atom(item) ->
              Ash.Resource.Info.relationship(query.resource, item)

            {item, _} ->
              Ash.Resource.Info.relationship(query.resource, item)
          end)

        %{query | side_load: new_load}
    end
  end

  defp side_load_query_with_reverse_path(
         root_query,
         related_query,
         reverse_path,
         root_data_filter
       ) do
    case Ash.Filter.parse(root_query.resource, root_query.filter) do
      {:ok, parsed} ->
        related_query
        |> Ash.Query.unset(:side_load)
        |> Ash.Query.filter(
          ^put_nested_relationship(
            [],
            reverse_path,
            root_data_filter,
            false
          )
        )
        |> Ash.Query.filter(^put_nested_relationship([], reverse_path, parsed, false))
        |> Ash.Query.filter(^related_query.filter)
        |> extract_errors()

      {:error, error} ->
        {:error, error}
    end
  end

  defp side_load_query(
         relationship,
         related_query,
         path,
         root_query
       ) do
    Request.resolve([[:data, :data]], fn %{data: %{data: data}} ->
      data =
        case data do
          %page{results: results} when page in [Ash.Page.Keyset, Ash.Page.Offset] ->
            results

          data ->
            data
        end

      root_data_filter =
        case data do
          [] ->
            false

          [%resource{} = item] ->
            item
            |> Map.take(Ash.Resource.Info.primary_key(resource))
            |> Enum.to_list()

          [%resource{} | _] = items ->
            pkey = Ash.Resource.Info.primary_key(resource)
            [or: Enum.map(items, fn item -> item |> Map.take(pkey) |> Enum.to_list() end)]
        end

      case reverse_relationship_path(
             relationship,
             Enum.drop(path, 1)
           ) do
        {:ok, reverse_path} ->
          side_load_query_with_reverse_path(
            root_query,
            related_query,
            reverse_path,
            root_data_filter
          )

        _ ->
          relationship.destination
          |> Ash.Query.new(related_query.api)
          |> Ash.Query.filter(^related_query.filter)
          |> extract_errors()
      end
    end)
  end

  defp extract_errors(%{errors: []} = item), do: {:ok, item}
  defp extract_errors(%{errors: errors}), do: {:error, errors}

  defp true_side_load_query(relationship, query, data, path, pagination_options) do
    {source_field, path} =
      if relationship.type == :many_to_many do
        join_relationship = join_relationship(relationship)

        {relationship.destination_field_on_join_table,
         join_relationship_path(path, join_relationship) |> Enum.map(& &1.name)}
      else
        {relationship.source_field, path |> Enum.reverse() |> Enum.map(& &1.name)}
      end

    source_data =
      case path do
        [] ->
          Map.get(data, :data)

        path ->
          data
          |> Map.get(:side_load, %{})
          |> Map.get(path, %{})
      end

    case source_data do
      %{data: empty} when empty in [[], nil] ->
        :nothing

      empty when empty in [[], nil] ->
        :nothing

      _ ->
        get_query(query, relationship, source_data, source_field, pagination_options)
    end
  end

  defp get_query(query, relationship, source_data, source_field, pagination_options) do
    {offset, limit} = offset_and_limit(query, relationship, pagination_options)

    cond do
      lateral_join?(query, relationship, pagination_options) ->
        {:ok, Ash.Query.unset(query, :side_load)}

      limit || offset ->
        {:ok, Ash.Query.unset(query, [:side_load, :limit, :offset])}

      true ->
        related_data = Map.get(source_data || %{}, :data, [])

        related_data =
          case related_data do
            %page{results: results} when page in [Ash.Page.Keyset, Ash.Page.Offset] ->
              results

            data ->
              data
          end

        ids =
          Enum.flat_map(related_data, fn data ->
            data
            |> Map.get(source_field)
            |> List.wrap()
          end)

        filter_value =
          case ids do
            [id] ->
              id

            ids ->
              [in: ids]
          end

        new_query =
          query
          |> Ash.Query.filter(^[{relationship.destination_field, filter_value}])
          |> Ash.Query.unset(:side_load)

        {:ok, new_query}
    end
  end

  def reverse_relationship_path(relationship, prior_path, acc \\ [])

  def reverse_relationship_path(nil, _, _) do
    :error
  end

  def reverse_relationship_path(relationship, [], acc) do
    relationship.destination
    |> Ash.Resource.Info.relationships()
    |> Enum.find(fn destination_relationship ->
      reverse_relationship?(relationship, destination_relationship)
    end)
    |> case do
      nil ->
        :error

      reverse ->
        {:ok, Enum.reverse([reverse.name | acc])}
    end
  end

  def reverse_relationship_path(relationship, [next_relationship | rest], acc) do
    relationship.destination
    |> Ash.Resource.Info.relationships()
    |> Enum.find(fn destination_relationship ->
      reverse_relationship?(relationship, destination_relationship)
    end)
    |> case do
      nil ->
        :error

      reverse ->
        reverse_relationship_path(next_relationship, rest, [reverse.name | acc])
    end
  end

  defp reverse_relationship?(rel, destination_rel) do
    rel.source == destination_rel.destination &&
      rel.source_field == destination_rel.destination_field &&
      rel.destination_field == destination_rel.source_field &&
      Map.fetch(rel, :source_field_on_join_table) ==
        Map.fetch(destination_rel, :destination_field_on_join_table) &&
      Map.fetch(rel, :destination_field_on_join_table) ==
        Map.fetch(destination_rel, :source_field_on_join_table)
  end

  defp put_nested_relationship(request_filter, path, value, records?) when not is_list(value) do
    put_nested_relationship(request_filter, path, [value], records?)
  end

  defp put_nested_relationship(request_filter, [rel | rest], values, records?) do
    [
      {rel, put_nested_relationship(request_filter, rest, values, records?)}
    ]
  end

  defp put_nested_relationship(request_filter, [], [{field, value}], _) do
    [{field, value} | request_filter]
  end

  defp put_nested_relationship(request_filter, [], [{field, _} | _] = keys, _) do
    [{field, [{:in, Enum.map(keys, &elem(&1, 1))}]} | request_filter]
  end

  defp put_nested_relationship(request_filter, [], [values], _) do
    List.wrap(request_filter) ++ List.wrap(values)
  end

  defp put_nested_relationship(request_filter, [], values, _) do
    Keyword.update(request_filter, :or, values, &Kernel.++(&1, values))
  end
end

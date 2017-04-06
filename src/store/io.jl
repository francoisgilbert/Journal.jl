module io

export IOStore

using Base.Dates

using JSON

using ...Journal
using ...utils
using ..store

"""Basic IO (files, streams) log store"""
immutable IOStore <: Store
    io::IO
    template::Function
    parser::Function
    timestamp_format::DateFormat
    function IOStore(;
        io::IO=STDERR,
        format::AbstractString="\$timestamp: \$level: \$name: \$topic: \$message",
        timestamp_format::Union{DateFormat, AbstractString}=ISODateTimeFormat
    )
        template = make_template(format)
        parser = make_parser(format)
        new(io, template, parser, timestamp_format)
    end
end
function IOStore(data::Dict{Symbol, Any})
    if haskey(data, :file)
        file = pop!(data, :file)
        if !isa(file, AbstractVector)
            file = [file]
        end
        if length(file) == 1
            # default to read/write
            push!(file, "w+")
        end
        data[:io] = open(file...)
    end
    IOStore(; data...)
end

function Base.print(io::IO, x::IOStore)
    print(io, "io: ", x.io)
end
Base.show(io::IO, x::IOStore) = print(io, x)

function Base.write(store::IOStore,
    timestamp::DateTime, level::LogLevel, name::Symbol, topic::AbstractString, message::Any;
    async::Bool=false, kwargs...
)
    data = store.template(;
        timestamp=Base.Dates.format(timestamp, store.timestamp_format),
        level=level, name=name, topic=topic, message=json(message)
    )
    write(store.io, data, '\n')
    flush(store.io)
end

"""Converts record fields to original types"""
function convert_entry(x)
    x[:timestamp] = DateTime(x[:timestamp], timestamp_format)
    x[:level] = haskey(x, :level) ? convert(LogLevel, x[:level]) : ON
    x[:name] = haskey(x, :name) ? Symbol(x[:name]) : Symbol()
    if !haskey(x, :topic)
        x[:topic] = ""
    end
    x[:message] = haskey(x, :message) ? JSON.parse(x[:message]) : nothing
    x
end

function Base.read{T <: Any}(store::IOStore;
    start::Union{TimeType, Void}=nothing,
    finish::Union{TimeType, Void}=nothing,
    filter::Associative{Symbol, T}=Dict{Symbol, Any}()
)
    if !isreadable(store.io)
        error("IO is not readable")
    end
    if (start !== nothing) && (finish !== nothing) && (start > finish)
        error("Start cannot be after finish: $start, $finish")
    end
    invalid = setdiff(keys(filter), [:level, :name, :topic])
    if !isempty(invalid)
        warn("Unapplied filters: ", join(invalid, ", "))
        filter = Base.filter((k, v) -> in(k, [:level, :name, :topic]), filter)
    end
    filter = map((k, v) -> k => isa(v, AbstractVector) ? v : [v], filter)

    seek(store.io, 0)
    entries = map(store.parser, readlines(store.io))
    entries = Base.filter!((x) -> haskey(x, :timestamp), entries)  # remove any non-conforming records
    entries = map!(convert_entry, entries)

    # apply any filters
    if (start !== nothing) || (finish !== nothing) || !isempty(filter)
        if start === nothing
            start = typemin(DateTime)
        end
        if finish === nothing
            finish = typemax(DateTime)
        end
        check(x) = (start <= x[:timestamp] <= finish) && all(in(x[k], v) for (k, v) in filter)
        entries = Base.filter!(check, entries)
    end
    entries
end

end
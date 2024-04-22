using BenchmarkTools
using MacroTools
using Test
using Base: input_color
using BenchmarkTools: TrialJudgement

include("structs.jl")
include("prefix.jl")


# Builds a tree from the ground up
function updateTestTreeUpwards!(tree_builder :: AbstractArray, name :: Union{String, Expr})

    # Get depth level
    depth = length(tree_builder)

    # Concatenate expressions of the current level into a new node on the upper level
    concat = :(Nothing)

    for expr in tree_builder[depth]
        concat = :($concat; $expr)
    end

    if depth > 1
        push!(tree_builder[depth-1],
            quote
                @testset $name (showtiming = false) begin
                    push!(depth, PerfTests.DepthRecord($name))
                    $concat
                    pop!(depth)
                end
            end
        )

        # Delete last level
        pop!(tree_builder)
    else
        pop!(tree_builder)
        push!(tree_builder, Expr[
            quote
                tt[$name] = (@testset $name (showtiming = false) begin
                    push!(depth, PerfTests.DepthRecord($name))
                    $concat
                    pop!(depth)
                end)
            end
        ])
    end
end


function updateTestTreeUpwardsFor!(tree_builder::AbstractArray, name::Union{String,Expr}, context :: Context)

    # Get depth level
    depth = length(tree_builder)

    # Concatenate expressions of the current level into a new node on the upper level
    concat = :(Nothing)

    for expr in tree_builder[depth]
        concat = :($concat; $expr)
    end

    i,n = last(context.depth).on_for

    if depth > 1
        push!(tree_builder[depth-1],
              quote
                @testset $name (showtiming = false) for $i in $n
                    push!(depth, PerfTests.DepthRecord($name * "_" * string($i)))
                    $concat
                    pop!(depth)
                end
              end
              )
        # Delete last level
        pop!(tree_builder)
    else
        pop!(tree_builder)
        push!(tree_builder, Expr[
            quote
                tt[$name] = (@testset $name (showtiming = false) for $i in $n
                    push!(depth, PerfTests.DepthRecord($name * "_" * string($i)))
                    $concat
                    pop!(depth)
                end)
            end
        ])
    end
end

function updateTestTreeDownwards!(tree_builder :: AbstractArray)
    # Add new level
    push!(tree_builder, Expr[])
end

function updateTestTreeSideways!(tree_builder::AbstractArray, name::String)

    # Get depth level
    depth = length(tree_builder)

    # Add the expression to de tree builder
    push!(tree_builder[depth],
          quote
            push!(depth, PerfTests.DepthRecord($name))
            @test PerfTests.inRange(tolerance, PerfTests.by_index(judgement, depth).ratio.time)

            if PerfTests.inRange(tolerance, PerfTests.by_index(judgement, depth).ratio.time)
                    else
                        PerfTests.printdepth!(depth)
                        PerfTests.printfail(PerfTests.by_index(judgement, depth), PerfTests.by_index(suite, depth), PerfTests.by_index(reference[1], depth), tolerance, length(depth))
                    end

            pop!(depth)
          end)
end

function testsetToBenchGroup!(input_expr :: Expr, context :: Context)
    # Get the elements of interest from the macrocall
    @capture(input_expr, @testset properties__ test_block_) ? Nothing : error("Incompatible testset syntax \n");

    # Get the name from the list of elements of the testset macrocall
    name = meta_get_string(properties);

    # Check if there is a for loop over the testset
    theres_for = @capture(test_block, for a_ in b_
        inner_block_
    end)

    # Update context: add depth level
    rec = ASTWalkDepthRecord(name)
    rec.on_for = theres_for ? Pair(a,b) : nothing
    push!(context.depth, rec)

    # Update context: add new level to the tree
    updateTestTreeDownwards!(context.test_tree_expr_builder)

    if theres_for
        @capture(test_block, for a_ in b_
            inner_block_
        end)

        return length(context.depth) > 1 ?
            :(
            for $a in $b
                l[$name * "_" * string($a)] = BenchmarkGroup();
                let l = l[$name * "_" * string($a)]
                    $inner_block
                end;
                :__BACK_CONTEXT__;
            end;
        ) :
            :(
            :__PERFTEST_FW__;
            for $a in $b
                l[$name * "_" * string($a)] = BenchmarkGroup();
                let l = l[$name * "_" * string($a)]
                    $inner_block
                end;
                :__BACK_CONTEXT__;
            end;
        )
    else
        # Return the substitution
        return length(context.depth) > 1 ?
               :(
            l[$name] = BenchmarkGroup();
            let l = l[$name]
                $test_block
            end;

            :__BACK_CONTEXT__
        ) :
               :(
            :__PERFTEST_FW__;

            l = BenchmarkGroup();
            let l = l[$name]
                $test_block
            end;

            :__BACK_CONTEXT__
        )
    end
end

function backTokenToContextUpdate!(input_expr ::QuoteNode, context::Context)

    # Check if inside a for loop
    if last(context.depth).on_for != nothing
        # Update context: consolidate tree level
        updateTestTreeUpwardsFor!(context.test_tree_expr_builder,
                           last(context.depth).depth_name, context)
    else
        updateTestTreeUpwards!(context.test_tree_expr_builder,
                           last(context.depth).depth_name)
    end
    # Update context: delete depth level
    pop!(context.depth)

    return nothing;
end

function perftestToBenchmark!(input_expr::Expr, context::Context)
    # Get the elements of interest from the macrocall
    @capture(input_expr, @perftest prop__ expr_)

    num = (last(context.depth).depth_test_count += 1)
    name = "Test $num"

    # Update context: create expression on tree builder
    updateTestTreeSideways!(context.test_tree_expr_builder, name)

    # Return the substitution and setup the in target flag deactivator
    return quote
        l[$name] = @benchmark ($expr);
        :__CONTEXT_TARGET_END__
    end
end


function scopeAssignment(input_expr::Expr, context::Context)::Expr
    # If inside a benchmark target, assignments are removed since they become useless

    if context.inside_target

        @show input_expr
        @capture(input_expr, a_ = b_)

        return quote
            $b
        end
    else
        return input_expr
    end
end

function scopeArg(input_expr::Expr, context::Context)::Expr

    if context.inside_target
        @capture(input_expr, f_(args__))

        processed_args = [isa(arg, Symbol) ?
            :($(Expr(:$,arg))) :
            arg for arg in args]

        return Expr(:call, f, processed_args...)
    else
        return input_expr
    end
end

function argProcess(args :: Vector)::Vector
    newargs = []
    for arg in args
        @show arg
        if isa(arg, Symbol)
            push!(newargs, :($(Expr(:$,arg))))
        elseif arg.head == :tuple
            push!(newargs, Expr(:tuple, argProcess(arg.args)...))
        else
            push!(newargs, arg)
        end
    end
    return newargs
end

function scopeVecFArg(input_expr::Expr, context::Context)::Expr

    if context.inside_target
        @capture(input_expr, f_.(args__))

        @show f
        @show args

        # Process symbols
        processed_args = argProcess(args)

        @show processed_args

        return Expr(:., f, Expr(:tuple, processed_args...))
    else
        return input_expr
    end
end

function scopeDotInterpolation(input_expr::Expr, context::Context)::Expr
    # If inside a benchmark target, the left side of the dot is interpolated to prevent failure reaching values stored in local scopes

    if context.inside_target
        @capture(input_expr, a_.b_)
        if (isa(a, Symbol))
            return :(
                $(Expr(:$,a)).$b
            )
        else
            return input_expr
        end
    else
        return input_expr
    end
end

## CONDITION RULES:
# TESTSET SUBSTITUTION

testset_macro_rule = ASTRule(
    x -> @capture(x, @testset __),
    (x, ctx) -> testsetToBenchGroup!(x, ctx)
)

# TESTS

test_macro_rule = ASTRule(
    x -> @capture(x, @test __),
    (x, ex_state) -> :(nothing)
)

test_throws_macro_rule = ASTRule(
    x -> @capture(x, @test_throws __),
    (x, ex_state) -> :(nothing)
)

test_logs_macro_rule = ASTRule(
    x -> @capture(x, @test_logs __),
    (x, ex_state) -> :(nothing)
)

inferred_macro_rule = ASTRule(
    x -> @capture(x, @inferred __),
    (x, ex_state) -> :(nothing)
)

test_deprecated_macro_rule = ASTRule(
    x -> @capture(x, @test_deprecated __),
    (x, ex_state) -> :(nothing)
)

test_warn_macro_rule = ASTRule(
    x -> @capture(x, @test_warn __),
    (x, ex_state) -> :(nothing)
)

test_nowarn_macro_rule = ASTRule(
    x -> @capture(x, @test_nowarn __),
    (x, ex_state) -> :(nothing)
)

test_broken_macro_rule = ASTRule(
    x -> @capture(x, @test_broken __),
    (x, ex_state) -> :(nothing)
)

test_skip_macro_rule = ASTRule(
    x -> @capture(x, @test_skip __),
    (x, ex_state) -> :(nothing)
)

# PERFTEST TARGET OBSERVERS

perftest_macro_rule = ASTRule(
    x -> @capture(x, @perftest __),
    (x, ctx) -> perftestToBenchmark!(x, ctx)
)

perftest_begin_macro_rule = ASTRule(
    x -> @capture(x, @benchmark __),
    (x, ctx) -> (ctx.inside_target = true; x)
)

perftest_scope_assignment_macro_rule = ASTRule(
    x -> @capture(x, _ = _),
    (x, ctx) -> scopeAssignment(x, ctx)
)

perftest_scope_arg_macro_rule = ASTRule(
    x -> @capture(x, _(__)),
    (x, ctx) -> scopeArg(x, ctx)
)

perftest_scope_vecf_arg_macro_rule = ASTRule(
    x -> @capture(x, _.(__)),
    (x, ctx) -> scopeVecFArg(x, ctx)
)

perftest_dot_interpolation_rule = ASTRule(
    x -> @capture(x, _._),
    (x, ctx) -> scopeDotInterpolation(x, ctx)
)

perftest_end_macro_rule = ASTRule(
    x -> x == :(:__CONTEXT_TARGET_END__),
    (x, ctx) -> (ctx.inside_target = false; nothing)
)

# TOKEN OBSERVERS

back_macro_rule = ASTRule(
    x -> (x == :(:__BACK_CONTEXT__)),
    (x, ctx) -> backTokenToContextUpdate!(x, ctx)
)

prefix_macro_rule = ASTRule(
    x -> (x == :(:__PERFTEST_FW__)),
    (x, ctx) -> perftestprefix(ctx)
)

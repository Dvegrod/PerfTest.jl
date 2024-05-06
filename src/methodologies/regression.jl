include("../structs.jl")
include("../config.jl")
include("../perftest/structs.jl")
include("../perftest/data_handling.jl")
include("../metrics.jl")

# THIS FILE SAVES THE MAIN COMPONENTS OF THE REGRESSION METHODOLOGY BEHAVIOUR

function regressionPrefix(ctx::Context)::Expr
    return regression.enabled ?
           quote
        # Get reference trials given the specified calculation policy
        $(
            if regression.regression_calculation == :latest
                quote
                    try
                        global reference = last(data.results).benchmarks
                    catch e
                    end
                end
            elseif regression.regression_calculation == :average
                quote
                    reference_components::Vector{BenchmarkGroup} = []
                    for result in data.results
                        push!(reference_components, result.benchmarks)
                        # TODO
                    end
                    global reference = reference_components[1]
                end
            else
                error("Invalid: regression.regression_calculation")
            end
        )
    end : quote
        nothing
    end
end

function regressionSuffix(ctx::Context)::Expr
    if regression.enabled
        return quote
            if res_num > 0

                # Estimates
                median_reference = median(reference)
                min_reference = minimum(reference)
                # Ratios
                median_ratio = ratio(median_suite, median_reference)
                min_ratio = ratio(min_suite, min_reference)
            else
                PerfTests.p_yellow("[ℹ]")
                println(" Regression: No previous results.")
            end
        end
    else
        return quote nothing end
    end
end

function regressionEvaluation()::Expr
    return regression.enabled ? quote
        if res_num > 0
            # Setup result collecting struct
            methodology_result = PerfTests.Methodology_Result(
                name = "REGRESSION TESTING",
                metrics = Pair{PerfTests.Metric_Result, PerfTests.Metric_Constraint}[]
            )

            # Metric data generation
            $(medianTime(
                configFallBack(metrics.median_time.regression_threshold,
                               :regression)))
            #$(testMinTime())
            #$(testMeanMemory())
            #$(testMinMemory())
            #$(testMeanAllocs())
            #$(testMinAllocs())

            # Metric print
            PerfTests.printMethodology(methodology_result, length(depth))

            # Metric actual test
            for pair in methodology_result.metrics
                @test pair.second.succeeded
            end
        end
    end : quote
        nothing
    end
end

using Dates
include("config.jl")
include("perftest/structs.jl")
include("methodologies/regression.jl")

### PREFIX FILLER
function perftestprefix(ctx :: Context)::Expr
    return quote
        using Test;
        using BenchmarkTools;

        # __PERFTEST__.Test.eval(quote
        #     function record(ts::DefaultTestSet, t::Union{Fail,Error})
        #         push!(ts.results, t)
        #     end
        # end)

        suite_name = $("$(basename(ctx.original_file_path))_PERFORMANCE")


        # Used to save data about this test suite if needed
        path = "./$(PerfTests.save_folder)/$(suite_name).JLD2"

        nofile = true
        if isfile(path)
            nofile = false
            data = PerfTests.openDataFile(path)
        else
            data = PerfTests.Perftest_Datafile_Root(PerfTests.Perftest_Result[])

            PerfTests.p_yellow("[!]")
            println("Regression: No previous performance reference for this configuration has been found, measuring performance without evaluation.")
        end

        l = BenchmarkGroup()

        $(regressionPrefix(ctx))
    end
end

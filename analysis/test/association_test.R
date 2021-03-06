# Copyright 2014 Google Inc. All rights reserved.
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Authors: vpihur@google.com (Vasyl Pihur), fanti@google.com (Giulia Fanti)

library(RUnit)
source("../R/encode.R")
source("../R/decode.R")
source("../R/simulation.R")
source("../R/association.R")

SamplePopulations <- function(N, num_variables = 1, params,
                              variable_opts) {
  # Samples a number of variables. User specifies the number of variables
  #     and some desired properties of those variables.
  #
  # Args:
  #   N: Number of reports to generate.
  #   params: RAPPOR parameters, like Bloom filter size, number of
  #       hash bits, etc.
  #   variable_opts: List of options for generating the ground truth:
  #       independent = whether distinct variables should be independently drawn
  #       deterministic = whether the variables should be drawn from a
  #           Poisson distribution or uniformly assigned across the range
  #           of 1:num_strings
  #       num_strings: Only does something if deterministic == TRUE, and
  #           specifies how many strings to use in the uniform assignment
  #           of ground truth strings.
  #
  # Returns:
  #   RAPPOR simulated ground truth for each piece of data.

  m <- params$m
  num_strings <- variable_opts$num_strings

  if (variable_opts$deterministic) {
    # If a deterministic distribution is desired, evenly distribute
    #     strings across all cohorts.

    reps <- ceiling(N / num_strings)
    variables <- lapply(1:num_variables,
                        function(i)
                        as.vector(sapply(1:num_strings, function(x)
                                         rep(x, reps)))[1:N])
    cohorts <- lapply(1:num_variables,
                      function(i) rep(1:m, ceiling(N / m))[1:N])
  } else {
    # Otherwise, draw from a Poisson random variable
    variables <- lapply(1:num_variables, function(i) rpois(N, 1))
    if (!variable_opts$independent) {
      # If user wants dependent RVs, take the cumulative sum of 3 independent
      #     random variables.
      variables <- as.list(data.frame(t(apply(do.call("rbind",
                                                      variables),
                                              2, cumsum))))
      # Use the same cohort assignment in all 3 dimensions so the
      #     correlations are preserved
      cohort <- sample(1:params$m, N, replace = TRUE)
      cohorts <- lapply(1:num_variables,
                        function(i) cohort)
    } else {
      # Randomly assign cohorts in each dimension
      cohorts <- lapply(1:num_variables,
                        function(i) sample(1:params$m, N, replace = TRUE))
    }
  }
  list(variables = variables, cohorts = cohorts)
}

Simulate <- function(N, num_variables, params, variable_opts = NULL,
                     truth = NULL, basic = FALSE) {
  if (is.null(truth)) {
    truth <- SamplePopulations(N, num_variables, params,
                               variable_opts)
  }
  #strs <- lapply(truth$variables, function(x) sort(unique(x)))
  strs <- lapply(truth$variables, function(x) 1:length(unique(x)))

  # Construct lists of maps and reports
  if (variable_opts$deterministic) {
    # Build the maps
    map <- CreateMap(strs[[1]], params, FALSE, basic = basic)
    maps <- lapply(1:num_variables, function(x) map)
    # Build the reports
    report <- EncodeAll(truth$variables[[1]], truth$cohorts[[1]],
                        map$map, params)
    reports <- lapply(1:num_variables, function(x) report)
  } else {
    # Build the maps
    maps <- lapply(1:num_variables, function(x)
                   CreateMap(strs[[x]], params, FALSE,
                             basic = basic))
    # Build the reports
    reports <- lapply(1:num_variables, function(x)
                      EncodeAll(truth$variables[[x]], truth$cohorts[[x]],
                                maps[[x]]$map, params))
  }

  list(reports = reports, cohorts = truth$cohorts,
       truth = truth$variables, maps = maps, strs = strs)

}

# ----------------Actual testing starts here--------------- #
TestComputeDistributionEM <- function() {
  # Test various aspects of ComputeDistributionEM in association.R.
  #     Tests include:
  #     Test 1: Compute a joint distribution of uniformly distributed,
  #         perfectly correlated strings
  #     Test 2: Compute a marginal distribution of uniformly distributed strings
  #     Test 3: Check the "other" category estimation works by removing
  #          a string from the known map.
  #     Test 4: Test that the variance from EM algorithm is 1/N when there
  #          is no noise in the system.
  #     Test 5: CHeck that the right answer is still obtained when f = 0.2./

  num_variables <- 3
  N <- 100

  # Initialize the parameters
  params <- list(k = 12, h = 2, m = 4, p = 0, q = 1, f = 0)
  variable_opts <- list(deterministic = TRUE, num_strings = 2,
                        independent = FALSE)
  sim <- Simulate(N, num_variables, params, variable_opts)

  # Test 1: Delta function pmf
  joint_dist <- ComputeDistributionEM(sim$reports,
                                      sim$cohorts, sim$maps,
                                      ignore_other = TRUE, params,
                                      marginals = NULL,
                                      estimate_var = FALSE)
  # The recovered distribution should be the delta function.
  checkEqualsNumeric(joint_dist$fit[1, 1, 1], 0.5)
  checkEqualsNumeric(joint_dist$fit[2, 2, 2], 0.5)

  # Test 2: Now compute a marginal using EM
  dist <- ComputeDistributionEM(list(sim$reports[[1]]),
                                list(sim$cohorts[[1]]),
                                list(sim$maps[[1]]),
                                ignore_other = TRUE,
                                params, marginals = NULL,
                                estimate_var = FALSE)
  checkEqualsNumeric(dist$fit[1], 0.5)

  # Test 3: Check that the "other" category is correctly computed
  # Build a modified map with no column 2 (i.e. we only know that string
  #     "1" is a valid string
  map <- sim$maps[[1]]
  small_map <- map

  for (i in 1:params$m) {
    locs <- which(map$map[[i]][, 1])
    small_map$map[[i]] <- sparseMatrix(locs, rep(1, length(locs)),
                                       dims = c(params$k, 1))
    locs <- which(map$rmap[, 1])
    colnames(small_map$map[[i]]) <- sim$strs[1]
  }
  small_map$rmap <- do.call("rBind", small_map$map)

  dist <- ComputeDistributionEM(list(sim$reports[[1]]),
                                list(sim$cohorts[[1]]),
                                list(small_map),
                                ignore_other = FALSE,
                                params,
                                marginals = NULL,
                                estimate_var = FALSE)

  # The recovered distribution should be uniform over 2 strings.
  checkTrue(abs(dist$fit[1] - 0.5) < 0.1)


  # Test 4: Test the variance is 1/N
  variable_opts <- list(deterministic = TRUE, num_strings = 1)
  sim <- Simulate(N, num_variables = 1, params, variable_opts)
  dist <- ComputeDistributionEM(sim$reports, sim$cohorts,
                                sim$maps, ignore_other = TRUE,
                                params, marginals = NULL,
                                estimate_var = TRUE)

  checkEqualsNumeric(dist$em$var_cov[1, 1], 1 / N)

  # Test 5: Check that when f=0.2, we still get a good estimate
  params <- list(k = 12, h = 2, m = 2, p = 0, q = 1, f = 0.2)
  variable_opts <- list(deterministic = TRUE, num_strings = 2)
  sim <- Simulate(N, num_variables = 2, params, variable_opts)
  dist <- ComputeDistributionEM(sim$reports, sim$cohorts,
                                sim$maps, ignore_other = TRUE,
                                params, marginals = NULL,
                                estimate_var = FALSE)

  checkTrue(abs(dist$fit[1, 1] - 0.5) < 0.15)

}

TestDecode <- function() {
  # Tests various aspects of Decode() in decode.R.
  #     Tests include:
  #     Test 1: Compute a distribution of uniformly distributed strings
  #     Test 2: Verify that the variance of the estimate is 0.

  num_variables <- 1
  N <- 100

  # Initialize the parameters
  params <- list(k = 12, h = 2, m = 2, p = 0, q = 1, f = 0)
  variable_opts <- list(deterministic = TRUE, num_strings = 2,
                        independent = FALSE)
  sim <- Simulate(N, num_variables, params, variable_opts)

  # Test 1: Uniform pmf
  variable_report <- EncodeAll(sim$truth[[1]], sim$cohorts[[1]],
                               sim$maps[[1]]$map, params)
  variable_counts <- ComputeCounts(variable_report, sim$cohorts[[1]],
                                   params)
  marginal <- Decode(variable_counts, sim$maps[[1]]$rmap, params)$fit

  # The recovered distribution should be uniform over 2 strings.
  checkTrue(abs(marginal$proportion[1] - 0.5) < 0.05)

  # Test 2: Make sure the std deviation is 0, since there was no noise
  checkEqualsNumeric(marginal$std_dev[1], 0)

  # Test 3: Basic RAPPOR
  num_strings <- 4
  basic = TRUE
  params <- list(k = num_strings, h = 1, m = 1, p = 0, q = 1, f = 0)
  variable_opts <- list(deterministic = TRUE, num_strings = num_strings)
  sim <- Simulate(N, num_variables, params, variable_opts,
                  basic = basic)
  variable_report <- EncodeAll(sim$truth[[1]], sim$cohorts[[1]],
                               sim$maps[[1]]$map, params)
  variable_counts <- ComputeCounts(variable_report, sim$cohorts[[1]],
                                   params)
  marginal <- Decode(variable_counts, sim$maps[[1]]$rmap, params)$fit

  checkEqualsNumeric(marginal$proportion[1], 0.25)

}

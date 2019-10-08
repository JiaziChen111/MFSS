% Test MFVAR

% David Kelley, 2018

classdef mfvar_test < matlab.unittest.TestCase
  
  properties
    data = struct;
  end
  
  methods(TestClassSetup)
    function setupOnce(testCase)
      % Load data
      baseDir = fileparts(fileparts(mfilename('fullpath')));
      addpath(baseDir);
      addpath(fullfile(baseDir, 'examples'));

      data_load = load(fullfile(baseDir, 'examples', 'durbin_koopman.mat'));
      testCase.data.nile = data_load.nile;
    end
  end
  
  methods(TestClassTeardown)
    function closeFigs(testCase) %#ok<MANU>
%       close all force;
    end
  end

  methods (Test)
    %% Integration tests of MFVAR
    function testEM_AR1_improve(testCase)
      % Test that the the EM always improved the likelihood
      nile = testCase.data.nile;
      varE = MFVAR(nile, 1);
      testCase.verifyWarningFree(@varE.estimate);
    end
    
    function testEM_AR1(testCase)
      % Test that the EM is working by comparing it to general ML estimation
      
      nile = testCase.data.nile;
      
      % Estimate MFVAR
      varE = MFVAR(nile, 1);
      varOpt = varE.estimate();
      [~, llEM] = varOpt.filter(nile);
      
      % Estimate general state space optimization
      ssE = StateSpaceEstimation(1, 0, nan, nan, 'c', nan);
      ssE.a0 = varOpt.a0;
      ssE.P0 = varOpt.P0;
      ssOpt = ssE.estimate(nile, varOpt);
      [~, llOpt] = ssOpt.filter(nile);
      
      testCase.verifyEqual(llEM, llOpt, 'AbsTol', 1e-2);
    end
    
    function testEM_VAR2_missing(testCase)
      % This test currently fails on the 244th iteration (by 0.14)
      p = 3; 
      lags = 2;
      seed = 12;
      
      y = mfvar_test.generateVAR(p, lags, 51, seed);
      y(1:45, 3) = nan;

      varE = MFVAR(y, lags);
      testCase.verifyWarningFree(@varE.estimate);
    end
    
    function testEM_VAR2_accum(testCase)
      % Thus currently works with T-1 and T! (but takes a long time).
      p = 3; 
      lags = 2;
      seed = 10;
      timeSteps = 51;
      
      y = mfvar_test.generateVAR(p, lags, timeSteps, seed); 
      aggY = y;
      aggY(:, 2) = Accumulator_test.aggregateY(y(:, 2), 3, 'avg');
      accum = Accumulator.GenerateRegular(aggY, {'', 'avg'}, [1 3]);

      varE = MFVAR(aggY, lags, accum);
      testCase.verifyWarningFree(@varE.estimate);
    end
    
    function testEM_VAR2_accum_missing(testCase)
      % This test currently fails on the 7th iteration of the EM algorithm (by 1).
      p = 3; 
      lags = 2;
      seed = 1e2;
      
      y = mfvar_test.generateVAR(p, lags, 51, seed);
      aggY = y;
      aggY(:, 2) = Accumulator_test.aggregateY(y(:, 2), 3, 'avg');
      accum = Accumulator.GenerateRegular(aggY, {'', 'avg'}, [1 3]);
      aggY(1:45,3) = nan;

      varE = MFVAR(aggY, lags, accum);
      testCase.verifyWarningFree(@varE.estimate);
    end
    
    %% Gibbs sampler tests   
    function testGibbs_AR1(testCase)      
      testCase.assumeTrue()
      
      nile = testCase.data.nile;
      varE = MFVAR(nile, 1);
      [~, paramSamples] = varE.sample(100, 1000);
      
      ssML = varE.estimate();
      testCase.verifyEqual(ssML.T, median(paramSamples.phi,3), 'AbsTol', 1e-2);
    end
    
    function testGibbs_VAR2(testCase)     
      testCase.assumeTrue()
      
      test_data = mfvar_test.generateVAR(2, 3, 100);
      varE = MFVAR(test_data, 1);
      [~, paramSamples] = varE.sample(100, 2000);
      
      ssML = varE.estimate();
      testCase.verifyEqual(ssML.T, median(paramSamples.phi,3), 'AbsTol', 1e-2);
    end
    
  end
  
  methods (Static)    
    function [y, ss, phi] = generateVAR(p, lags, n, seed)
      % Generate a set of VAR parameters. 
      % 
      % Not intended for large systems (will be slow with many series)
      if nargin < 4
        seed = 0;
      end
      rng(seed);
      
      phi2T = @(phi) [phi; eye(p*(lags-1)) zeros(p*(lags-1), p)];
      
      phi = [2*eye(p) zeros(p,p*(lags-1))];
      while max(abs(eig(phi2T(phi)))) > 1
        phiRaw = 0.2*randn(p, p*lags) + [.5*eye(p) zeros(p,p*(lags-1))];
        phi = phiRaw - ...
          [eye(p)*(max(abs(eig(phi2T(phiRaw))))-1) zeros(p, p*(lags-1))];
      end
      const = randn(p,1);
      sigma = 0;
      while det(sigma) <= 0
        sigmaRaw = randn(p);
        sigma = eye(p) + 0.5 * (sigmaRaw + sigmaRaw');
      end
      
      ss = StateSpace([eye(p) zeros(p,p*(lags-1))], zeros(p), ...
        phi2T(phi), sigma, 'c', [const; zeros(p*(lags-1),1)], ...
        'R', [eye(p); zeros(p*(lags-1),p)]);
      
      y = generateData(ss, n)';
    end    
  end
end

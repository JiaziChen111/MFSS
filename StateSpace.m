classdef StateSpace < AbstractStateSpace
  % State estimation of models with known parameters 
  %
  % Includes filtering/smoothing algorithms and maximum likelihood
  % estimation of parameters with restrictions.
  %
  % StateSpace Properties:
  %   Z, d, H - Observation equation parameters
  %   T, c, R, Q - Transition equation parameters
  %   a0, P0 - Initial value parameters
  %
  % StateSpace Methods:
  %   
  % Object construction
  % -------------------
  %   ss = StateSpace(Z, d, H, T, c, R, Q)
  %
  % The d & c parameters may be entered as empty for convenience.
  %
  % Time varrying parameters may be passed as structures with a field for
  % the parameter values and a vector indicating the timing. Using Z as an
  % example the field names would be Z.Zt and Z.tauZ.
  %
  % Filtering & smoothing
  % ---------------------
  %   [a, logl] = ss.filter(y)
  %   alpha = ss.smooth(y)
  %
  % Additional estimates from the filter (P, v, F, M, K, L) and
  % smoother (eta, r, N, a0tilde) are returned in the filterValues and
  % smootherValues structures. The multivariate filter also returns w and
  % Finv (the inverse of F). The multivariate smoother also returns V and J.
  %
  % When the initial value parameters are not passed or are empty, default
  % values will be generated as either the stationary solution (if it exists)
  % or the approximate diffuse case with large kappa. The value of kappa
  % can be set with ss.kappa before the use of the filter/smoother.
  %
  % The univariate filter/smoother will be used if H is diagonal. Set
  % ss.filterUni to false to force the use of the multivaritate versions.
  %
  % Mex versions will be used unless ss.useMex is set to false or the mex
  % files cannot be found.
  
  % David Kelley, 2016-2017
  %
  % TODO (1/17/17)
  % ---------------
  %   - Add filter/smoother weight decompositions
  %   - Add IRF/historical decompositions
  
  methods (Static)
    %% Static properties
    function returnVal = useMex(newVal)
      % Static function to mimic a static class property of whether the mex 
      % functions should be used (avoids overhead of checking for them every time)
      persistent useMex_persistent;
      
      % Setter
      if nargin > 0 && ~isempty(newVal)
        useMex_persistent = newVal;
      end
      
      % Default setter
      if isempty(useMex_persistent)
        % Check mex files exist
        mexMissing = any([...
          isempty(which('mfss_mex.kfilter_uni'));
          isempty(which('mfss_mex.kfilter_multi'));
          isempty(which('mfss_mex.ksmoother_uni'));
          isempty(which('mfss_mex.ksmoother_multi'));
          isempty(which('mfss_mex.gradient_multi'))]);
        if mexMissing
          useMex_persistent = false;
          warning('MEX files not found. See .\mex\make.m');
        else
          useMex_persistent = true;
        end
      end

      % Getter
      returnVal = useMex_persistent;
    end
  end
  
  methods
    %% Constructor
    function obj = StateSpace(Z, d, H, T, c, R, Q)
      % StateSpace constructor
      % Pass state parameters to construct new object (or pass a structure
      % containing the neccessary parameters)
      obj = obj@AbstractStateSpace(Z, d, H, T, c, R, Q);
      
      obj.validateStateSpace();
      
      % Check if we can use the univariate filter
      slicesH = num2cell(obj.H, [1 2]);
      obj.filterUni = ~any(~cellfun(@isdiag, slicesH));
    end
    
    %% State estimation methods 
    function [a, logli, filterOut] = filter(obj, y)
      % FILTER Estimate the filtered state
      % 
      % a = StateSpace.FILTER(y) returns the filtered state given the data y. 
      %
      % a = StateSpace.FILTER(y, a0) 
      % a = StateSpace.FILTER(y, a0, P0) returns the filtered state given the 
      % data y and initial state estimates a0 and P0. 
      %
      % [a, logli] = StateSpace.FILTER(...) also returns the log-likelihood of
      % the data. 
      % [a, logli, filterOut] = StateSpace.FILTER(...) returns an additional
      % structure of intermediate computations useful in other functions. 
      
      [obj, y] = obj.prepareFilter(y);
      
      % Call the filter
      if obj.useMex
        [a, logli, filterOut] = obj.filter_mex(y);
      else
        [a, logli, filterOut] = obj.filter_m(y);
      end
    end
    
    function [alpha, smootherOut, filterOut] = smooth(obj, y)
      % Estimate the smoothed state
      
      [obj, y] = obj.prepareFilter(y);

      % Get the filtered estimates for use in the smoother
      [~, logli, filterOut] = obj.filter(y);
      
      % Determine which version of the smoother to run
      if obj.useMex
        [alpha, smootherOut] = obj.smoother_mex(y, filterOut);
      else
        [alpha, smootherOut] = obj.smoother_m(y, filterOut);
      end
      
      smootherOut.logli = logli;
    end
    
    function [logli, gradient] = gradient(obj, y, tm, theta)
      % Returns the likelihood and the change in the likelihood given the
      % change in any system parameters that are currently set to nans.
      
      % Most of the prepareFilter function:
      obj.validateKFilter();
      obj = obj.checkSample(y);
      obj = setDefaultInitial(obj);

      assert(isa(tm, 'ThetaMap'));
      if nargin < 4
        theta = tm.system2theta(obj);
      end
      
      % Generate parameter gradient structure
      G = tm.parameterGradients(theta);
      [G.a0, G.P0] = tm.initialValuesGradients(theta, G);
      
      [alpha, sOut, fOut] = obj.smooth(y);
      logli = sOut.logli;
      
%       e = obj.getErrors(y, fOut.a(:,1:obj.n));
      epsilon = obj.getErrors(y, alpha);
      [V, D, J] = obj.getErrorVariances(fOut, sOut);
%       u = sOut.alpha - fOut.a(:,1:obj.n);
      [u, D] = obj.getGradientQuantities(epsilon, sOut);
%       u3 = epsilon - e;
      
      % Stick the last filtered estimate on the end of alpha since we'll need
      % \hat{alpha}_{t+1|T}
      alpha = [alpha fOut.a(:,end)]; 
      
      gradient = obj.gradient_uni_m(y, alpha, u, D, sOut.r, sOut.N, epsilon, V, J, G);        
    end
    
    function [dataDecomposition, constContrib] = decompose_smoothed(obj, y, decompPeriods)
      % Decompose the smoothed states by data contributions
      %
      % Output ordered by (state, observation, contributingPeriod, effectPeriod)
      
      [obj, y] = obj.prepareFilter(y);

      if nargin < 3
        decompPeriods = 1:obj.n;
      end
      
      [~, ~, fOut] = obj.filter(y);
      if obj.useMex
        [alpha, sOut] = obj.smoother_mex(y, fOut);
      else
        [alpha, sOut] = obj.smoother_m(y, fOut);
      end
      
      [alphaW, constContrib] = obj.smoother_weights(y, fOut, sOut, decompPeriods);
      
      % Apply weights to data
      cleanY = y;
      cleanY(isnan(y)) = 0;
      
      nDecomp = length(decompPeriods);
      dataDecomposition = zeros(obj.m, obj.p, obj.n, nDecomp);
      % Loop over periods effected
      for iT = 1:nDecomp
        % Loop over contributing periods
        for cT = 1:obj.n 
          dataDecomposition(:,:,cT,iT) = alphaW(:,:,cT,iT) .* repmat(cleanY(:, cT)', [obj.m, 1]);
        end
      end
      
      % Weights come out ordered (state, observation, origin, effect) so
      % collapsing the 2nd and 3rd dimension should give us a time-horizontal
      % sample. 
      dataContrib = squeeze(sum(sum(dataDecomposition, 2), 3));
      if obj.m == 1
        dataContrib = dataContrib';
      end
      alpha_test = dataContrib + constContrib;
      err = alpha(:,decompPeriods) - alpha_test;
      assert(max(max(abs(err))) < 0.001, 'Did not recover data from decomposition.');
    end
    
    %% Utilties
    function obj = setDefaultInitial(obj, reset)
      % Set default a0 and P0.
      % Run before filter/smoother after a0 & P0 inputs have been processed
      
      if nargin < 2 
        % Option to un-set initial values. 
        reset = false;
      end
      if reset
        obj.usingDefaulta0 = true;
        obj.usingDefaultP0 = true;
        obj.a0 = [];
        obj.A0 = [];
        obj.R0 = [];
        obj.Q0 = [];
      end        
      
      if ~obj.usingDefaulta0 && ~obj.usingDefaultP0
        % User provided a0 and P0.
        return
      end
      
      if isempty(obj.tau)
        obj = obj.setInvariantTau();
      end
      
      % Find stationary states and compute the unconditional mean and variance
      % of them using the parts of T, c, R and Q. For the nonstationary states,
      % set up the A0 selection matrix. 
      [stationary, nonstationary] = obj.findStationaryStates();
      
      tempT = obj.T(stationary, stationary, obj.tau.T(1));
      assert(all(abs(eig(tempT)) < 1));
      
      select = eye(obj.m);
      mStationary = length(stationary);

      if obj.usingDefaulta0
        obj.a0 = zeros(obj.m, 1);
        
        a0temp = (eye(mStationary) - tempT) \ obj.c(stationary, obj.tau.c(1));
        obj.a0(stationary) = a0temp;
      end
      
      if obj.usingDefaultP0
        obj.A0 = select(:, nonstationary);
        obj.R0 = select(:, stationary);
        
        tempR = obj.R(stationary, :, obj.tau.R(1));
        tempQ = obj.Q(:, :, obj.tau.Q(1));
        try
          obj.Q0 = reshape((eye(mStationary^2) - kron(tempT, tempT)) \ ...
            reshape(tempR * tempQ * tempR', [], 1), ...
            mStationary, mStationary);
        catch ex
          % If the state is large, try making it sparse
          if strcmpi(ex.identifier, 'MATLAB:array:SizeLimitExceeded')
            tempT = sparse(tempT);
            obj.Q0 = full(reshape((speye(mStationary^2) - kron(tempT, tempT)) \ ...
              reshape(tempR * tempQ * tempR', [], 1), ...
              mStationary, mStationary));
          else
            rethrow(ex);
          end
        end
        
      end
    end
  end
  
  methods (Hidden)
    %% Filter/smoother Helper Methods
    function obj = checkSample(obj, y)
      assert(size(y, 1) == obj.p, ...
        'Number of series does not match observation equation.');
      % TODO: check that we're not observing accumulated series before the end
      % of a period.
      
      if ~obj.timeInvariant
        % System with TVP, make sure length of taus matches data.
        assert(size(y, 2) == obj.n);
      else
        % No TVP, set n then set tau as ones vectors of that length.
        obj.n = size(y, 2);
        obj = obj.setInvariantTau();
      end
    end
    
    function validateStateSpace(obj)
      % Check dimensions of inputs to Kalman filter.
      if obj.timeInvariant
        maxTaus = ones([7 1]);
      else
        maxTaus = structfun(@max, obj.tau);  % Untested?
      end
      
      validate = @(x, sz, name) validateattributes(x, {'numeric'}, ...
        {'size', sz}, 'StateSpace', name);
      
      % Measurement equation
      validate(obj.Z, [obj.p obj.m maxTaus(1)], 'Z');
      validate(obj.d, [obj.p maxTaus(2)], 'd');
      validate(obj.H, [obj.p obj.p maxTaus(3)], 'H');
      
      % State equation
      validate(obj.T, [obj.m obj.m maxTaus(4)], 'T');
      validate(obj.c, [obj.m maxTaus(5)], 'c');
      validate(obj.R, [obj.m obj.g maxTaus(6)], 'R');
      validate(obj.Q, [obj.g obj.g maxTaus(7)], 'Q');
    end
    
    function validateKFilter(obj)
      obj.validateStateSpace();
      
      % Make sure all of the parameters are known (non-nan)
      assert(~any(cellfun(@(x) any(any(any(isnan(x)))), obj.parameters)), ...
        ['All parameter values must be known. To estimate unknown '...
        'parameters, see StateSpaceEstimation']);
    end
    
    function [ssUni, y, factorC] = factorMultivariate(obj, y)
      % Compute new Z and H matricies so the univariate treatment can be applied
      
      % If H is already diagonal, do nothing
      if arrayfun(@(x) isdiag(obj.H(:,:,x)), 1:size(obj,3))
        ssUni = obj;
        ssUni.filterUni = true;
        return
      end
      
      [uniqueOut, ~, newTauH] = unique([obj.tau.H ~isnan(y')], 'rows');
      oldTauH = uniqueOut(:,1);
      obsPattern = uniqueOut(:,2:end);
      
      % Create factorizations
      maxTauH = max(newTauH);
      factorC = zeros(size(obj.H, 1), size(obj.H, 2), maxTauH);
      newHmat = zeros(size(obj.H, 1), size(obj.H, 2), maxTauH);
      for iH = 1:maxTauH
        ind = logical(obsPattern(iH, :));
        [factorC(ind,ind,iH), newHmat(ind,ind,iH)] = ldl(obj.H(ind,ind,oldTauH(iH)), 'lower');
        assert(isdiag(newHmat(ind,ind,iH)), 'ldl returned non-diagonal d matrix.');
      end
      newH = struct('Ht', newHmat, 'tauH', newTauH);      
      
      for iT = 1:size(y,2)
        % Transform observations
        ind = logical(obsPattern(newTauH(iT),:));
        y(ind,iT) = factorC(ind,ind,newTauH(iT)) * y(ind,iT);
      end
      
      % We may need to create more slices of Z. 
      % If a given slice of Z is used when two different H matricies are used,
      % we need to use the correct C matrix to factorize it at each point. 
      [uniqueOut, ~, newTauZ] = unique([obj.tau.Z newTauH ~isnan(y')], 'rows');
      oldTauZ = uniqueOut(:,1);
      correspondingNewHOldZ = uniqueOut(:,2);
      obsPattern = uniqueOut(:,3:end);
      
      newZmat = zeros([size(obj.Z, 1) size(obj.Z, 2), max(newTauZ)]);
      for iZ = 1:max(newTauZ)
        ind = logical(obsPattern(iZ,:));
        newZmat(ind,:,iZ) = factorC(ind,ind,correspondingNewHOldZ(iZ)) \ obj.Z(ind,:,oldTauZ(iZ));
      end
      newZ = struct('Zt', newZmat, 'tauZ', newTauZ);
      
      % Same thing for d
      [uniqueOut, ~, newTaud] = unique([obj.tau.d newTauH ~isnan(y')], 'rows');
      oldTaud = uniqueOut(:,1);
      correspondingNewHOldd = uniqueOut(:,2);
      obsPattern = uniqueOut(:,3:end);

      newdmat = zeros([size(obj.d, 1) max(newTaud)]);
      for id = 1:max(newTaud)
        ind = logical(obsPattern(id,:));
        newdmat(ind,id) = factorC(ind,ind,correspondingNewHOldd(id)) \ obj.d(ind,oldTaud(id));
      end
      newd = struct('dt', newdmat, 'taud', newTaud);
      
      % State matricies
      if ~isempty(obj.tau)
        T = struct('Tt', obj.T, 'tauT', obj.tau.T);
        c = struct('ct', obj.c, 'tauc', obj.tau.c);
        R = struct('Rt', obj.R, 'tauR', obj.tau.R);
        Q = struct('Qt', obj.Q, 'tauQ', obj.tau.Q);
      else
        T = obj.T;
        c = obj.c;
        R = obj.R;
        Q = obj.Q;
      end
      
      ssUni = StateSpace(newZ, newd, newH, T, c, R, Q);
      
      % Set initial values
      P0 = obj.R0 * obj.Q0 * obj.R0';
      P0(obj.A0 * obj.A0' == 1) = Inf;
      ssUni = ssUni.setInitial(obj.a0, P0);
    end
    
    function [obj, y] = prepareFilter(obj, y)
      % Make sure data matches observation dimensions
      obj.validateKFilter();
      obj = obj.checkSample(y);
      
      % Set initial values
      obj = setDefaultInitial(obj);

      % Handle multivariate series
      [obj, y] = obj.factorMultivariate(y);
    end
    
    function [obsErr, stateErr] = getErrors(obj, y, state, a0)
      % Get the errors epsilon & eta given an estimate of the state 
      % Either the filtered or smoothed estimates can be calculated by passing
      % either the filtered state (a) or smoothed state (alphaHat).
      
      % With the state already estimated, we simply have to back out the errors.
      
      % Make sure the object is set up correctly but DO NOT factor as is done 
      % for the univariate filter. 
      if isempty(obj.n)
        obj.n = size(state, 2);
        obj = obj.setInvariantTau();
      else
        assert(obj.n == size(state, 2), ...
          'Size of state doesn''t match time dimension of StateSpace.');
      end
      
      % Iterate through observations
      obsErr = nan(obj.p, obj.n);
      for iT = 1:obj.n
        obsErr(:,iT) = y(:,iT) - ...
          obj.Z(:,:,obj.tau.Z(iT)) * state(:,iT) - obj.d(:,obj.tau.d(iT));        
      end
      
      % Potentially return early
      if nargout < 2
        stateErr = [];
        return
      end
      
      % Iterate through states
      Rbar = nan(obj.g, obj.m, size(obj.R, 3));
      for iR = 1:size(obj.R, 3)
        Rbar(:,:,iR) = (obj.R(:,:,iR)' * obj.R(:,:,iR)) \ obj.R(:,:,iR)';
      end
      
      stateErr = nan(obj.g, obj.n);
      stateErr(:,1) = Rbar(:,:,obj.tau.R(iT)) * (state(:,1) - ...
        obj.T(:,:,obj.tau.T(1)) * a0 - obj.c(:,obj.tau.c(1)));
      for iT = 2:obj.n
        stateErr(:,iT) = Rbar(:,:,obj.tau.R(iT)) * (state(:,iT) - ...
          obj.T(:,:,obj.tau.T(iT)) * state(:,iT-1) - obj.c(:,obj.tau.c(iT)));
      end
    end
    
    function [V, D, J] = getErrorVariances(obj, fOut, sOut)
      % Get the smoothed state variance and covariance matricies
      % Produces V = Var(alpha | Y_n) and J = Cov(alpha_{t+1}, alpha_t | Y_n)
      computeJ = nargout > 2;
      
      I = eye(obj.m);
      Hinv = nan(obj.p, obj.p, size(obj.H, 3));
      for iH = 1:size(obj.H, 3)
        Hinv(:,:,iH) = AbstractSystem.pseudoinv(obj.H(:,:,iH), 1e-12);
      end
            
      V = nan(obj.m, obj.m, obj.n);
      D = nan(obj.m, obj.m, obj.n);
      J = nan(obj.m, obj.m, obj.n);
      for iT = obj.n:-1:1
        Zii = obj.Z(:,:,obj.tau.Z(iT));
        iP = fOut.P(:,:,iT);

        % TODO: This needs to be corrected for the exact initial. See DK p. 133.
        V(:,:,iT) = iP - iP * sOut.N(:,:,iT) * iP;
        D(:,:,iT) = Hinv(:,:,obj.tau.H(iT)) * ...
          (obj.H(:,:,obj.tau.H(iT)) - V(:,:,iT)) * ...
          Hinv(:,:,obj.tau.H(iT));
        
        if computeJ
          % TODO: Can we do this without the F inverses?
          F = Zii * iP * Zii' + obj.H(:,:,obj.tau.H(iT));
          K = obj.T(:,:,obj.tau.T(iT)) * iP * Zii' / F;
          L = obj.T(:,:,obj.tau.T(iT)) - K * obj.Z(:,:,obj.tau.Z(iT));

          J(:,:,iT) = iP * L' * (I - sOut.N(:,:,iT+1) * fOut.P(:,:,iT+1));
        end
      end
    end
    
    function [smootherErr, smoothErrVar] = getGradientQuantities(obj, epsilon, V)
      % Generate needed quantites for the gradient
      
      % See Durbin & Koopman  sec. 4.5.1 and 5.4
      % We're generating u and D here.
      % Based on \hat{epsilon} = H * u, back out u based on epsilon.
      % Based on Var(alpha | Y_n) = V = H - H * D * H, back out D based on V. 
      smootherErr = nan(obj.p, obj.n);
      smoothErrVar = zeros(obj.p, obj.p, obj.n);
      for iT = 1:obj.n
        smootherErr(:,iT) = obj.H(:,:,obj.tau.H(iT)) \ epsilon(:,iT);
%         smoothErrVar(:,:,iT) = diag(fOut.F(:,iT)) + ...
%           fOut.K(:,:,iT)' * sOut.N(:,:,iT) * fOut.K(:,:,iT);
      end
    end
    
    %% Filter/smoother/gradient mathematical methods
    function [a, logli, filterOut] = filter_m(obj, y)
      % Filter using exact initial conditions
      %
      % See "Fast Filtering and Smoothing for Multivariate State Space Models",
      % Koopman & Durbin (2000) and Durbin & Koopman, sec. 7.2.5.
              
      assert(isdiag(obj.H), 'Univarite only!');
      
      % Preallocate
      % Note Pd is the "diffuse" P matrix (P_\infty).
      a = zeros(obj.m, obj.n+1);
      v = zeros(obj.p, obj.n);
      
      Pd = zeros(obj.m, obj.m, obj.n+1);
      Pstar = zeros(obj.m, obj.m, obj.n+1);
      Fd = zeros(obj.p, obj.n);
      Fstar = zeros(obj.p, obj.n);
      
      Kd = zeros(obj.m, obj.p, obj.n);
      Kstar = zeros(obj.m, obj.p, obj.n);
      
      LogL = zeros(obj.p, obj.n);
      
      % Initialize - Using the FRBC timing 
      ii = 0;
      Tii = obj.T(:,:,obj.tau.T(ii+1));
      a(:,ii+1) = Tii * obj.a0 + obj.c(:,obj.tau.c(ii+1));
      
      Pd0 = obj.A0 * obj.A0';
      Pstar0 = obj.R0 * obj.Q0 * obj.R0';
      Pd(:,:,ii+1)  = Tii * Pd0 * Tii';
      Pstar(:,:,ii+1) = Tii * Pstar0 * Tii' + ...
        obj.R(:,:,obj.tau.R(ii+1)) * obj.Q(:,:,obj.tau.Q(ii+1)) * obj.R(:,:,obj.tau.R(ii+1))';

      ii = 0;
      % Initial recursion
      while ~all(all(Pd(:,:,ii+1) == 0))
        if ii >= obj.n
          error(['Degenerate model. ' ...
          'Exact initial filter unable to transition to standard filter.']);
        end
        
        ii = ii + 1;
        ind = find( ~isnan(y(:,ii)) );
        
        ati = a(:,ii);
        Pstarti = Pstar(:,:,ii);
        Pdti = Pd(:,:,ii);
        for jj = ind'
          Zjj = obj.Z(jj,:,obj.tau.Z(ii));
          v(jj,ii) = y(jj, ii) - Zjj * ati - obj.d(jj,obj.tau.d(ii));
          
          Fd(jj,ii) = Zjj * Pdti * Zjj';
          Fstar(jj,ii) = Zjj * Pstarti * Zjj' + obj.H(jj,jj,obj.tau.H(ii));
          
          Kd(:,jj,ii) = Pdti * Zjj';
          Kstar(:,jj,ii) = Pstarti * Zjj';
          
          if Fd(jj,ii) ~= 0
            % F diffuse nonsingular
            ati = ati + Kd(:,jj,ii) ./ Fd(jj,ii) * v(jj,ii);
            
            Pstarti = Pstarti + Kd(:,jj,ii) * Kd(:,jj,ii)' * Fstar(jj,ii) * (Fd(jj,ii).^-2) - ...
              (Kstar(:,jj,ii) * Kd(:,jj,ii)' + Kd(:,jj,ii) * Kstar(:,jj,ii)') ./ Fd(jj,ii);
            
            Pdti = Pdti - Kd(:,jj,ii) .* Kd(:,jj,ii)' ./ Fd(jj,ii);
            
            LogL(jj,ii) = log(Fd(jj,ii));
          else
            % F diffuse = 0
            ati = ati + Kstar(:,jj,ii) ./ Fstar(jj,ii) * v(jj,ii);
            
            Pstarti = Pstarti - Kstar(:,jj,ii) ./ Fstar(jj,ii) * Kstar(:,jj,ii)';

            LogL(jj,ii) = (log(Fstar(jj,ii)) + (v(jj,ii)^2) ./ Fstar(jj,ii));
          end
        end
        
        Tii = obj.T(:,:,obj.tau.T(ii+1));
        a(:,ii+1) = Tii * ati + obj.c(:,obj.tau.c(ii+1));
        
        Pd(:,:,ii+1)  = Tii * Pdti * Tii';
        Pstar(:,:,ii+1) = Tii * Pstarti * Tii' + ...
          obj.R(:,:,obj.tau.R(ii+1)) * obj.Q(:,:,obj.tau.Q(ii+1)) * obj.R(:,:,obj.tau.R(ii+1))';
      end
      
      dt = ii;
      
      F = Fstar;
      K = Kstar;
      P = Pstar;
      
      % Standard Kalman filter recursion
      for ii = dt+1:obj.n
        ind = find( ~isnan(y(:,ii)) );
        ati    = a(:,ii);
        Pti    = P(:,:,ii);
        for jj = ind'
          Zjj = obj.Z(jj,:,obj.tau.Z(ii));
          
          v(jj,ii) = y(jj,ii) - Zjj * ati - obj.d(jj,obj.tau.d(ii));
          
          F(jj,ii) = Zjj * Pti * Zjj' + obj.H(jj,jj,obj.tau.H(ii));
          K(:,jj,ii) = Pti * Zjj';
          
          LogL(jj,ii) = (log(F(jj,ii)) + (v(jj,ii)^2) / F(jj,ii));
          
          ati = ati + K(:,jj,ii) / F(jj,ii) * v(jj,ii);
          Pti = Pti - K(:,jj,ii) / F(jj,ii) * K(:,jj,ii)';
        end
        
        Tii = obj.T(:,:,obj.tau.T(ii+1));
        
        a(:,ii+1) = Tii * ati + obj.c(:,obj.tau.c(ii+1));
        P(:,:,ii+1) = Tii * Pti * Tii' + ...
          obj.R(:,:,obj.tau.R(ii+1)) * obj.Q(:,:,obj.tau.Q(ii+1)) * obj.R(:,:,obj.tau.R(ii+1))';
      end

      logli = -(0.5 * sum(sum(isfinite(y)))) * log(2 * pi) - 0.5 * sum(sum(LogL));
      
      filterOut = obj.compileStruct(a, P, Pd, v, F, Fd, K, Kd, dt);
    end
    
    function [a, logli, filterOut] = filter_mex(obj, y)
      % Call mex function filter_uni
      ssStruct = struct('Z', obj.Z, 'd', obj.d, 'H', obj.H, ...
        'T', obj.T, 'c', obj.c, 'R', obj.R, 'Q', obj.Q, ...
        'a0', obj.a0, 'A0', obj.A0, 'R0', obj.R0, 'Q0', obj.Q0, ...
        'tau', obj.tau);
      if isempty(ssStruct.R0)
        ssStruct.R0 = zeros(obj.m, 1);
        ssStruct.Q0 = 0;
      end
      if isempty(ssStruct.A0)
        ssStruct.A0 = zeros(obj.m, 1);
      end
      
      [a, logli, P, Pd, v, F, Fd, K, Kd, dt] = mfss_mex.filter_uni(y, ssStruct);
      filterOut = obj.compileStruct(a, P, Pd, v, F, Fd, K, Kd, dt);
    end
    
    function [alpha, smootherOut] = smoother_m(obj, y, fOut)
      % Univariate smoother
      
      alpha = zeros(obj.m, obj.n);
      eta   = zeros(obj.g, obj.n);
      r     = zeros(obj.m, obj.n);
      N     = zeros(obj.m, obj.m, obj.n+1);
      
      rti = zeros(obj.m,1);
      Nti = zeros(obj.m,obj.m);
      for ii = obj.n:-1:fOut.dt+1
        ind = flipud(find( ~isnan(y(:,ii)) ));
        
        for jj = ind'
          Lti = eye(obj.m) - fOut.K(:,jj,ii) * ...
            obj.Z(jj,:,obj.tau.Z(ii)) / fOut.F(jj,ii);
          rti = obj.Z(jj,:,obj.tau.Z(ii))' / ...
            fOut.F(jj,ii) * fOut.v(jj,ii) + Lti' * rti;
          Nti = obj.Z(jj,:,obj.tau.Z(ii))' / ...
            fOut.F(jj,ii) * obj.Z(jj,:,obj.tau.Z(ii)) ...
            + Lti' * Nti * Lti;
        end
        r(:,ii) = rti;
        N(:,:,ii) = Nti;
        
        alpha(:,ii) = fOut.a(:,ii) + fOut.P(:,:,ii) * r(:,ii);
        eta(:,ii) = obj.Q(:,:,obj.tau.Q(ii+1)) * obj.R(:,:,obj.tau.R(ii+1))' * r(:,ii); 
        
        rti = obj.T(:,:,obj.tau.T(ii))' * rti;
        Nti = obj.T(:,:,obj.tau.T(ii))' * Nti * obj.T(:,:,obj.tau.T(ii));
      end
      
      % Note: r0 = r;
      r1 = zeros(obj.m, fOut.dt+1);
      
      % Exact initial smoother
      for ii = fOut.dt:-1:1
        r0ti = r(:,ii+1);
        r1ti = r1(:,ii+1);
        
        ind = flipud(find( ~isnan(y(:,ii)) ));
        for jj = ind'
          Zjj = obj.Z(jj,:,obj.tau.Z(ii));
          
          if fOut.Fd(jj,ii) ~= 0 % ~isequal(Finf(ind(jj),ii),0)
            % Diffuse case
            Ldti = eye(obj.m) - fOut.Kd(:,jj,ii) * Zjj / fOut.Fd(jj,ii);
            L0ti = (fOut.Kd(:,jj,ii) * fOut.F(jj,ii) / fOut.Fd(jj,ii) + ...
              fOut.K(:,jj,ii)) * Zjj / fOut.Fd(jj,ii);
            
            r1ti = Zjj' / fOut.Fd(jj,ii) * fOut.v(jj,ii) - L0ti' * r0ti + Ldti' * r1ti;
            
            r0ti = Ldti' * r0ti;
          else
            % Known
            Lstarti = eye(obj.m) - fOut.K(:,jj,ii) * Zjj / fOut.F(jj,ii);
            r0ti = Zjj' / fOut.F(jj,ii) * fOut.v(jj,ii) + Lstarti' * r0ti;
          end
        end
        r(:,ii) = r0ti;
        r1(:,ii) = r1ti;
        
        % What here needs tau_{ii+1}?
        alpha(:,ii) = fOut.a(:,ii) + fOut.P(:,:,ii) * r(:,ii) + ...
          fOut.Pd(:,:,ii) * r1(:,ii);
        
        eta(:,ii) = obj.Q(:,:,obj.tau.Q(ii)) * obj.R(:,:,obj.tau.R(ii))' * r(:,ii);
        
        r0ti = obj.T(:,:,obj.tau.T(ii))' * r0ti;
        r1ti = obj.T(:,:,obj.tau.T(ii))' * r1ti;
      end
      
      Pstar0 = obj.R0 * obj.Q0 * obj.R0';
      if fOut.dt > 0
        Pd0 = obj.A0 * obj.A0';
        a0tilde = obj.a0 + Pstar0 * r0ti + Pd0 * r1ti;
      else
        a0tilde = obj.a0 + Pstar0 * rti;
      end
      
      smootherOut = obj.compileStruct(alpha, eta, r, N, a0tilde);
    end
    
    function [alpha, smootherOut] = smoother_mex(obj, y, fOut)
      ssStruct = struct('Z', obj.Z, 'd', obj.d, 'H', obj.H, ...
        'T', obj.T, 'c', obj.c, 'R', obj.R, 'Q', obj.Q, ...
        'a0', obj.a0, 'A0', obj.A0, 'R0', obj.R0, 'Q0', obj.Q0, ...
        'tau', obj.tau);
      if isempty(ssStruct.R0)
        ssStruct.R0 = zeros(obj.m, 1);
        ssStruct.Q0 = 0;
      end
      if isempty(ssStruct.A0)
        ssStruct.A0 = zeros(obj.m, 1);
      end
      
      [alpha, eta, r, N, a0tilde] = mfss_mex.smoother_uni(y, ssStruct, fOut);
      smootherOut = obj.compileStruct(alpha, eta, r, N, a0tilde);
    end
    
    function gradient = gradient_uni_m(obj, y, alpha, u, D, r, N, epsilon, V, J, G)
      % Loglikelihood gradient calculation based on univariate smoother
      %
      % See Durbin & Koopman, sec. 7.3.3. 
      % See Jungbacker, Koopman & van der Wel (2011), Appendix B.
      
      % The derivative of the likelihood with respect to a parameter matrix is
      % denoted dldX for a parameter X. Also note the following name changes:
      %   This function         JKV                             
      %     V                     P_{t|n}
      %     J                     P_{t+1,t|n}
      %     d_t                   c_t
      %     c_t                   d_t
            
%       assert(all(all(all(G.R == 0))), ...
%         'JKV smoother gradient does not support estimated elements of R.');
      
      vec = @(M) reshape(M, [], 1);

      % Precompute commonly used matricies
      Rbar = nan(obj.g, obj.m, size(obj.R, 3));
      for iR = 1:size(obj.R, 3)
        Rbar(:,:,iR) = (obj.R(:,:,iR)' * obj.R(:,:,iR)) \ obj.R(:,:,iR)';
      end
      
      Hinv = nan(obj.p, obj.p, size(obj.H, 3));
      for iH = 1:size(obj.H, 3)
        Hinv(:,:,iH) = AbstractSystem.pseudoinv(obj.H(:,:,iH), 1e-12);
      end
      
      Qinv = nan(obj.g, obj.g, size(obj.Q, 3));
      for iQ = 1:size(obj.Q, 3)
        Qinv(:,:,iQ) = AbstractSystem.pseudoinv(obj.Q(:,:,iQ), 1e-12);
      end
      
      [uniqueRows, rowSource, tauRQR] = unique([obj.tau.R obj.tau.Q], 'rows');
      GRQR = nan(size(G.Q, 1), size(obj.R, 1).^2, max(tauRQR));
      Nm = AbstractStateSpace.genCommutation(obj.m) + eye(obj.m.^2);
      for iRQR = 1:max(tauRQR)
        % See Nagakura (working paper)
        itauR = uniqueRows(rowSource(iRQR), 1);
        itauQ = uniqueRows(rowSource(iRQR), 2);
        iR = obj.R(:,:,itauR);
        
        GRQR(:,:,iRQR) = G.R(:,:,itauR) * ...
          kron(obj.Q(:,:,itauQ) * iR', eye(obj.m)) * Nm + ...
          G.Q(:,:,itauQ) * kron(iR', iR');
      end
      
      dldZ = zeros(size(obj.Z));
      dldd = zeros(size(obj.d));
      dldH = zeros(size(obj.H));
      dldT = zeros(size(obj.T));
      dldc = zeros(size(obj.c));
      dldRQR = zeros(obj.m, obj.m);
      for iT = 1:obj.n
        % Observation equation gradients
        Zii = obj.Z(:,:,obj.tau.Z(iT));
        iHinv = Hinv(:,:,obj.tau.H(iT));

        % Gradient of Z
        MZ = alpha(:,iT) * alpha(:,iT)' + V(:,:,iT);
        dldZ(:,:,obj.tau.Z(iT)) = dldZ(:,:,obj.tau.Z(iT)) + ...
          iHinv * ((y(:,iT) - obj.d(:,obj.tau.d(iT))) * alpha(:,iT)' - Zii * MZ);
        
        % Gradient of d
        dldd(:,:,obj.tau.d(iT)) = dldd(:,:,obj.tau.d(iT)) + ...
          iHinv * epsilon(:,iT);
        
        % Gradient of H
        dldH(:,:,obj.tau.H(iT)) = dldH(:,:,obj.tau.H(iT)) + ...
          0.5 * (u(:,iT) * u(:,iT)' - D(:,:,iT));
        
        % State equation gradients - remember paramter tau timing is t+1
        % Gradient of T
        iQinv = Qinv(:,:,obj.tau.Q(iT+1));
        iRbarQinvRbar = Rbar(:,:,obj.tau.R(iT+1))' * ...
          iQinv * Rbar(:,:,obj.tau.R(iT+1));
        
        MT = alpha(:,iT+1) * alpha(:,iT)' + J(:,:,iT);
        dldT(:,:,obj.tau.T(iT+1)) = dldT(:,:,obj.tau.T(iT+1)) + ...
          iRbarQinvRbar * (MT - obj.T(:,:,obj.tau.T(iT+1)) * MZ);
        
        % Gradient of c
        dldc(:,:,obj.tau.c(iT+1)) = dldc(:,:,obj.tau.c(iT+1)) + ...
          iRbarQinvRbar * ...
          (alpha(:,iT+1) - obj.T(:,:,obj.tau.T(iT+1)) * alpha(:,iT) - ...
          obj.c(:,obj.tau.c(iT+1))); 
        
        % Gradient of R and Q
        % Looping over 1:n-1 here
        % Timing - r and N are actually lagged a period compared to any D&K
        % writeup (r(:,obj.n) != 0), r(:,obj.n+1) = 0)). 
%         if iT < obj.n
          dldRQR(:,:,tauRQR(iT+1)) =  dldRQR(:,:,tauRQR(iT+1)) + ...
            0.5 * (r(:,iT) * r(:,iT)' - N(:,:,iT));
%         end
      end
      
      gradient = G.Z * vec(dldZ) + G.d * vec(dldd) + G.H * vec(dldH) + ...
        G.T * vec(dldT) + G.c * vec(dldc) + GRQR * vec(dldRQR);
    end
    
    function gradient = gradient_multi_filter_m(obj, y, G, fOut)
      % Gradient algorithm from Diasuke Nagakura (SSRN # 1634552).
      %
      % Note that G.x is 3D for everything except a and P (and a0 and P0). 
      % G.a and G.P denote the one-step ahead gradient (i.e., G_\theta(a_{t+1}))
      
      nTheta = size(G.T, 1);
      
      Nm = (eye(obj.m^2) + obj.genCommutation(obj.m));
      vec = @(M) reshape(M, [], 1);
      
      % Compute partial results that have less time-variation (even with TVP)
      kronRR = zeros(obj.g*obj.g, obj.m*obj.m, max(obj.tau.R));
      for iR = 1:max(obj.tau.R)
        kronRR(:, :, iR) = kron(obj.R(:,:,iR)', obj.R(:,:,iR)');
      end
      
      [tauQRrows, ~, tauQR] = unique([obj.tau.R obj.tau.Q], 'rows');
      kronQRI = zeros(obj.g * obj.m, obj.m * obj.m, max(tauQR));
      for iQR = 1:max(tauQR)
        kronQRI(:, :, iQR) = kron(obj.Q(:,:,tauQRrows(iQR, 2)) * obj.R(:,:,tauQRrows(iQR, 1))', ...
          eye(obj.m));
      end
      
      % Initial period: G.a and G.P capture effects of a0, T
      P0 = obj.R0 * obj.Q0 * obj.R0';

      G.a = G.a0 * obj.T(:,:,obj.tau.T(1))' + ...
        G.c(:, :, obj.tau.c(1)) + ... % Yes, G.c is 3D.
        G.T(:,:,obj.tau.T(1)) * kron(obj.a0, eye(obj.m));
      G.P = G.P0 * kron(obj.T(:,:,obj.tau.T(1))', obj.T(:,:,obj.tau.T(1))') + ...
        G.Q(:,:,obj.tau.Q(1)) * kron(obj.R(:,:,obj.tau.R(1))', obj.R(:,:,obj.tau.R(1))') + ...
        (G.T(:,:,obj.tau.T(1)) * kron(P0 * obj.T(:,:,obj.tau.T(1))', eye(obj.m)) + ...
        G.R(:,:,obj.tau.R(1)) * kron(obj.Q(:,:,obj.tau.Q(1)) * ...
        obj.R(:,:,obj.tau.R(1))', eye(obj.m))) * ...
          Nm;
      
      % Recursion through time periods
      W_base = logical(sparse(eye(obj.p)));
      
      grad = zeros(obj.n, nTheta);
      for ii = 1:obj.n
        ind = ~isnan(y(:,ii));
        W = W_base((ind==1),:);
        kronWW = kron(W', W');
        
        Zii = W * obj.Z(:, :, obj.tau.Z(ii));
        
        ww = fOut.w(ind,ii) * fOut.w(ind,ii)';
        Mv = fOut.M(:,:,ii) * fOut.v(:, ii);
        
        grad(ii, :) = G.a * Zii' * fOut.w(ind,ii) + ...
          0.5 * G.P * vec(Zii' * ww * Zii - Zii' * fOut.Finv(ind,ind,ii) * Zii) + ...
          G.d(:,:,obj.tau.d(ii)) * W' * fOut.w(ind,ii) + ...
          G.Z(:,:,obj.tau.Z(ii)) * vec(W' * (fOut.w(ind,ii) * fOut.a(:,ii)' + ...
            fOut.w(ind,ii) * Mv' - fOut.M(:,ind,ii)')) + ...
          0.5 * G.H(:,:,obj.tau.H(ii)) * kronWW * vec(ww - fOut.Finv(ind,ind,ii));
        
        % Set t+1 values
        PL = fOut.P(:,:,ii) * fOut.L(:,:,ii)';
        
        kronZwL = kron(Zii' * fOut.w(ind,ii), fOut.L(:,:,ii)');
        kronPLw = kron(PL, fOut.w(:,ii));
        kronaMvK = kron(fOut.a(:,ii) + Mv, fOut.K(:,:,ii)');
        kronwK = kron(fOut.w(:,ii), fOut.K(:,:,ii)');
        kronAMvI = kron(fOut.a(:,ii) + Mv, eye(obj.m));
        
        G.a = G.a * fOut.L(:,:,ii)' + ...
          G.P * kronZwL + ...
          G.c(:,:,obj.tau.c(ii+1)) - ...
          G.d(:,:,obj.tau.d(ii)) * fOut.K(:,:,ii)' + ...
          G.Z(:,:,obj.tau.Z(ii)) * (kronPLw - kronaMvK) - ...
          G.H(:,:,obj.tau.H(ii)) * kronwK + ...
          G.T(:,:,obj.tau.T(ii+1)) * kronAMvI;
        
        kronLL = kron(fOut.L(:,:,ii)', fOut.L(:,:,ii)');
        kronKK = kron(fOut.K(:,:,ii)', fOut.K(:,:,ii)');
        kronPLI = kron(PL, eye(obj.m));
        kronPLK = kron(PL, fOut.K(:,:,ii)');
        
        G.P = G.P * kronLL + ...
          G.H(:,:,obj.tau.H(ii)) * kronKK + ...
          G.Q(:,:,obj.tau.Q(ii+1)) * kronRR(:,:, obj.tau.R(ii+1)) + ...
          (G.T(:,:,obj.tau.T(ii+1)) * kronPLI - ...
            G.Z(:,:,obj.tau.Z(ii)) * kronPLK + ...
            G.R(:,:,obj.tau.R(ii+1)) * kronQRI(:, :, tauQR(ii+1))) * ...
            Nm;
      end
      
      gradient = sum(grad, 1)';
    end
    
    function gradient = gradient_multi_filter_mex(obj, y, G, fOut)
      P0 = obj.R0 * obj.Q0 * obj.R0';
      
      ssStruct = struct('Z', obj.Z, 'd', obj.d, 'H', obj.H, ...
        'T', obj.T, 'c', obj.c, 'R', obj.R, 'Q', obj.Q, ...
        'a0', obj.a0, 'P0', P0, ...
        'tau', obj.tau, ...
        'p', obj.p, 'm', obj.m, 'g', obj.g, 'n', obj.n);
      
      gradient = mfss_mex.gradient_multi(y, ssStruct, G, fOut);
    end
    
    %% Decomposition mathematical methods
    function [alphaTweights, alphaTconstant] = smoother_weights(obj, y, fOut, sOut, decompPeriods)
      % Generate weights (effectively via multivariate smoother) 
      %
      % Weights ordered (state, observation, data period, state effect period)
      % Constant contributions are ordered (state, effect period)
      
      % pre-allocate W(j,t) where a(:,t) = \sum_{j=1}^{t-1} W(j,t)*y(:,j)
      alphaTweights = zeros(obj.m, obj.p, obj.n, length(decompPeriods)); 
      alphaTconstant = zeros(obj.m, length(decompPeriods)); 
      
      eyeP = eye(obj.p);
      genF = @(ind, iT) obj.Z(ind,:,obj.tau.Z(iT)) * fOut.P(:,:,iT) * obj.Z(ind,:,obj.tau.Z(iT))' ...
        + obj.H(ind,ind,obj.tau.H(iT));
      genK = @(indJJ, jT) obj.T(:,:,obj.tau.T(jT+1)) * fOut.P(:,:,jT) * ...
            obj.Z(indJJ,:,obj.tau.Z(jT))' * AbstractSystem.pseudoinv(genF(indJJ,jT), 1e-12);
      genL = @(ind, iT) obj.T(:,:,obj.tau.T(iT+1)) - ...
        genK(ind,iT) * (eyeP(ind,:) * obj.Z(:,:,obj.tau.Z(iT)));
      
      wb = waitbar(0, 'Creating smoother weights.');
      
      for iPer = 1:length(decompPeriods)
        iT = decompPeriods(iPer);
        ind = ~isnan(y(:,iT));
        
        iL = genL(ind, iT);
        lWeights = iL;
        % Loop through t,t+1,...,n to calculate weights and constant adjustment for j >= t
        for jT = iT:obj.n 
          indJJ = ~isnan(y(:,jT));
          Zjj = obj.Z(indJJ,:,obj.tau.Z(jT));
          Kjj = genK(indJJ, jT); % fOut.K(:,indJJ,jT);
          jL = genL(indJJ,jT);
          
          Finvjj = AbstractSystem.pseudoinv(genF(indJJ,jT), 1e-12);
          % Slight alternative calculation for the boundary condition for j == t
          if jT == iT
            PFZKNL = fOut.P(:,:,jT) * (Finvjj * Zjj - ...
              Kjj' * sOut.N(:,:,jT+1) * jL)';
            
            alphaTweights(:, indJJ, jT, iPer) = PFZKNL;            
            alphaTconstant(:,iPer) = -PFZKNL * ...
               obj.d(indJJ, obj.tau.d(jT)) + ...
              (eye(obj.m) - fOut.P(:,:,jT) * sOut.N(:,:,jT)) * obj.c(:,obj.tau.c(jT));
          else
            % weight and constant adjustment calculations for j >> t
            PL = fOut.P(:,:,iT) * lWeights;
            PLFZKNL = PL * (Finvjj * Zjj - ...
              Kjj' * sOut.N(:,:,jT+1) * jL)';
            
            alphaTweights(:,indJJ,jT,iPer) = PLFZKNL;
            alphaTconstant(:,iPer) = alphaTconstant(:,iPer) - ...
              PLFZKNL * obj.d(indJJ, obj.tau.d(jT)) - ...
              PL * sOut.N(:,:,jT) * obj.c(:,obj.tau.c(jT));
            lWeights = lWeights * jL';
          end
        end
        
        if iT > 1
          lWeights = (eye(obj.m) - fOut.P(:,:,iT) * sOut.N(:,:,iT));
        end
        % Loop through j = t-1,t-2,...,1 to calculate weights and constant adjustment for j < t
        for jT = iT-1:-1:1
          % find non-missing observations for time period "jj"
          indJJ = ~isnan(y(:,jT));
          jL = genL(ind,jT);

          if iT > jT
            lK =  lWeights * genK(indJJ,jT);
            alphaTweights(:,indJJ,jT,iPer) = lK;
            alphaTconstant(:,iPer) = alphaTconstant(:,iPer) + ...
              lWeights * jL * obj.c(:,obj.tau.c(jT)) - ...
              lK * obj.d(indJJ,obj.tau.d(jT));
            lWeights = lWeights * jL;
          end
        end
        
        waitbar(iPer ./ length(decompPeriods), wb);
      end

      delete(wb);
    end
    
    %% Initialization
    function [stationary, nonstationary] = findStationaryStates(obj)
      % Find which states have stationary distributions given the T matrix.
      [V, D] = eig(obj.T(:,:,obj.tau.T(1)));
      bigEigs = abs(diag(D)) >= 1;
      
      nonstationary = find(any(V(:, bigEigs), 2));
      
      % I think we don't need a loop here to find other states that have 
      % loadings on the nonstationary states (the eigendecomposition does this 
      % for us) but I'm not sure.
      stationary = setdiff(1:obj.m, nonstationary);      

      assert(all(abs(eig(obj.T(stationary,stationary,1))) < 1), ...
        ['Stationary section of T isn''t actually stationary. \n' ... 
        'Likely development error.']);
    end
  end
  
  methods (Static, Hidden)
    %% General Utility Methods
    function setSS = setAllParameters(ss, value)
      % Create a StateSpace with all paramters set to value
      
      % Set all parameter values equal to the scalar provided
      for iP = 1:length(ss.systemParam)
        ss.(ss.systemParam{iP})(:) = value;
      end
      
      % Needs to be a StateSpace since we don't want a ThetaMap
      setSS = StateSpace(ss.Z(:,:,1), ss.d(:,1), ss.H(:,:,1), ...
        ss.T(:,:,1), ss.c(:,1), ss.R(:,:,1), ss.Q(:,:,1));
      paramNames = ss.systemParam;
      for iP = 1:length(paramNames)
        setSS.(paramNames{iP}) = ss.(paramNames{iP});
      end
      setSS.tau = ss.tau;
      setSS.timeInvariant = ss.timeInvariant;
      setSS.n = ss.n;
      
      % Do I want to set initial values? 
      if ~isempty(ss.a0)
        a0value = repmat(value, [ss.m, 1]);
      else
        a0value = [];
      end
      setSS = setSS.setInitial(a0value);
      
      % Do I want to account for diffuse states? 
      if ~isempty(ss.Q0)
        setSS.A0 = ss.A0;
        setSS.R0 = ss.R0;
        
        Q0value = repmat(value, size(ss.Q0));  
        setSS = setSS.setQ0(Q0value);
      end
    end    
  end
end

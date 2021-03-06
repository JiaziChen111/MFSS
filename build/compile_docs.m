function docs_status = compile_docs
% Make the documentation for the MFSS toolbox
% 
% Compiling the documentation requires a conda environment named py27
% with python 2.7 installed and the following packages installed from pip:
%   sphinx
%   sphinxcontrib-matlabdomain

% David Kelley, 2017

buildDir = fileparts(mfilename('fullpath'));
docsDir = fullfile(fileparts(buildDir), 'docs');

[sphinx_status, sphinx_msg] = system(['activate py27 & ' docsDir '\make html']);
if sphinx_status == 0 && contains(sphinx_msg, 'build succeeded')
  docs_status = 0;
else
  docs_status = -1;
end
  
% Copy the helptoc.xml file so Matlab knows what documentation we have:
if docs_status == 0
  xmlSource = fullfile(docsDir, 'source', 'helptoc.xml');
  xmlDest = fullfile(docsDir, 'build', 'html', 'helptoc.xml');
  copyfile(xmlSource, xmlDest);
end


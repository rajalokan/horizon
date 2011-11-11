#!/bin/bash

set -o errexit

# ---------------UPDATE ME-------------------------------#
# Increment me any time the environment should be rebuilt.
# This includes dependncy changes, directory renames, etc.
# Simple integer secuence: 1, 2, 3...
environment_version=1
#--------------------------------------------------------#

function usage {
  echo "Usage: $0 [OPTION]..."
  echo "Run Horizon's test suite(s)"
  echo ""
  echo "  -V, --virtual-env        Always use virtualenv.  Install automatically"
  echo "                           if not present"
  echo "  -N, --no-virtual-env     Don't use virtualenv.  Run tests in local"
  echo "                           environment"
  echo "  -c, --coverage           Generate reports using Coverage"
  echo "  -f, --force              Force a clean re-build of the virtual"
  echo "                           environment. Useful when dependencies have"
  echo "                           been added."
  echo "  -p, --pep8               Just run pep8"
  echo "  -y, --pylint             Just run pylint"
  echo "  -q, --quiet              Run non-interactively. (Relatively) quiet."
  echo "  --skip-selenium          Run unit tests but skip Selenium tests"
  echo "  --runserver              Run the Django development server for"
  echo "                           openstack-dashboard in the virtual"
  echo "                           environment."
  echo "  --docs                   Just build the documentation"
  echo "  -h, --help               Print this usage message"
  echo ""
  echo "Note: with no options specified, the script will try to run the tests in"
  echo "  a virtual environment,  If no virtualenv is found, the script will ask"
  echo "  if you would like to create one.  If you prefer to run tests NOT in a"
  echo "  virtual environment, simply pass the -N option."
  exit
}

function process_option {
  case "$1" in
    -h|--help) usage;;
    -V|--virtual-env) always_venv=1; never_venv=0;;
    -N|--no-virtual-env) always_venv=0; never_venv=1;;
    -p|--pep8) just_pep8=1;;
    -y|--pylint) just_pylint=1;;
    -f|--force) force=1;;
    -q|--quiet) quiet=1;;
    -c|--coverage) with_coverage=1;;
    --skip-selenium) selenium=-1;;
    --docs) just_docs=1;;
    --runserver) runserver=1;;
    *) testargs="$testargs $1"
  esac
}

function run_server {
  echo "Starting Django development server..."
  ${django_wrapper} python openstack-dashboard/dashboard/manage.py runserver
  echo "Server stopped."
}

function run_pylint {
  echo "Running pylint ..."
  PYLINT_INCLUDE="openstack-dashboard/dashboard horizon/horizon"
  ${django_wrapper} pylint --rcfile=.pylintrc -f parseable $PYLINT_INCLUDE > pylint.txt || true
  CODE=$?
  grep Global -A2 pylint.txt
  if [ $CODE -lt 32 ]
  then
      echo "Completed successfully."
      exit 0
  else
      echo "Completed with problems."
      exit $CODE
  fi
}

function run_pep8 {
  echo "Running pep8 ..."
  rm -f pep8.txt
  PEP8_EXCLUDE=vcsversion.py
  PEP8_OPTIONS="--exclude=$PEP8_EXCLUDE --repeat"
  PEP8_INCLUDE="openstack-dashboard/dashboard horizon/horizon"
  echo "${django_wrapper} pep8 $PEP8_OPTIONS $PEP8_INCLUDE > pep8.txt"
  ${django_wrapper} pep8 $PEP8_OPTIONS $PEP8_INCLUDE > pep8.txt || true
  PEP8_COUNT=`wc -l pep8.txt | awk '{ print $1 }'`
  if [ $PEP8_COUNT -ge 1 ]; then
    echo "PEP8 violations found ($PEP8_COUNT):"
    cat pep8.txt
    echo "Please fix all PEP8 violations before committing."
  else
    echo "No violations found. Good job!"
  fi
}

function run_sphinx {
    echo "Building sphinx..."
    echo "export DJANGO_SETTINGS_MODULE=dashboard.settings"
    export DJANGO_SETTINGS_MODULE=dashboard.settings
    echo "${django_wrapper} sphinx-build -b html docs/source docs/build/html"
    ${django_wrapper} sphinx-build -b html docs/source docs/build/html
    echo "Build complete."
}

# DEFAULTS FOR RUN_TESTS.SH
#
venv=openstack-dashboard/.dashboard-venv
django_with_venv=openstack-dashboard/tools/with_venv.sh
dashboard_with_venv=tools/with_venv.sh
always_venv=0
never_venv=0
force=0
with_coverage=0
selenium=0
testargs=""
django_wrapper=""
dashboard_wrapper=""
just_pep8=0
just_pylint=0
just_docs=0
runserver=0
quiet=0

# PROCESS ARGUMENTS, OVERRIDE DEFAULTS
for arg in "$@"; do
    process_option $arg
done

function environment_check {
  echo "Checking environment."
  if [ -f .environment_version ]; then
    ENV_VERS=`cat .environment_version`
    if [ $ENV_VERS -eq $environment_version ]; then
      echo "Environment is up to date."
      return 0
    fi
  fi
  if [ $quiet -eq 1 ]; then
    install_venv
  else
    # If we didn't pass our check, ask about upgrading the environment.
    echo -e "Your environment appears to be out of date. Update? (Y/n) \c"
    read update_env
    if [ "x$update_env" = "xY" -o "x$update_env" = "x" -o "x$update_env" = "xy" ]; then
      install_venv
    fi
  fi
}

function sanity_check {
  # Anything that should be determined prior to running the tests, server, etc.
  if [ ! -f horizon/bin/test ]; then
    echo "Error: Test script not found at horizon/bin/test. Did buildout succeed?"
    exit 1
  fi
  if [ ! -f horizon/bin/coverage ]; then
    echo "Error: Coverage script not found at horizon/bin/coverage. Did buildout succeed?"
    exit 1
  fi
  if [ ! -f horizon/bin/seleniumrc ]; then
    echo "Error: Selenium script not found at horizon/bin/seleniumrc. Did buildout succeed?"
    exit 1
  fi
}

function install_venv {
  # Install openstack-dashboard with install_venv.py
  export PIP_DOWNLOAD_CACHE=/tmp/.pip_download_cache
  export PIP_USE_MIRRORS=true
  cd openstack-dashboard
  python tools/install_venv.py
  cd ..
  # Install horizon with buildout
  if [ ! -d /tmp/.buildout_cache ]; then
    mkdir -p /tmp/.buildout_cache
  fi
  cd horizon
  python bootstrap.py
  bin/buildout
  cd ..
  django_wrapper="${django_with_venv}"
  dashboard_wrapper="${dashboard_with_venv}"
  # Make sure it worked and record the environment version
  sanity_check
  echo $environment_version > .environment_version
}

if [ $never_venv -eq 0 ]
then
  # Remove the virtual environment if --force used
  if [ $force -eq 1 ]; then
    echo "Cleaning virtualenv..."
    rm -rf ${venv}
  fi
  if [ -e ${venv} ]; then
    django_wrapper="${django_with_venv}"
    dashboard_wrapper="${dashboard_with_venv}"
  else
    if [ $always_venv -eq 1 ]; then
      # Automatically install the virtualenv
      install_venv
    else
      if [ $quiet -eq 1 ]; then
        echo -e "No virtual environment found...create one? (Y/n) \c"
        read use_ve
        if [ "x$use_ve" = "xY" -o "x$use_ve" = "x" -o "x$use_ve" = "xy" ]; then
          # Install the virtualenv and run the test suite in it
          install_venv
        fi
      else
        install_venv
      fi
    fi
  fi
fi

function wait_for_selenium {
  # Selenium can sometimes take several seconds to start.
  STARTED=`grep -irn "Started SocketListener on 0.0.0.0:4444" .selenium_log`
  if [ $? -eq 0 ]; then
      echo "Selenium server started."
    else
      echo -n "."
      sleep 1
      wait_for_selenium
  fi
}

function run_tests {
  sanity_check

  if [ $selenium -eq 0 ]; then
    echo "Starting Selenium server..."
    ${django_wrapper} horizon/bin/seleniumrc > .selenium_log &
    wait_for_selenium
  fi

  echo "Running Horizon application tests"
  ${django_wrapper} coverage erase
  ${django_wrapper} coverage run horizon/bin/test
  # get results of the Horizon tests
  OPENSTACK_RESULT=$?

  echo "Running openstack-dashboard (Django project) tests"
  cd openstack-dashboard
  if [ -f local/local_settings.py ]; then
    cp local/local_settings.py local/local_settings.py.bak
  fi
  cp local/local_settings.py.example local/local_settings.py

  if [ $selenium -eq 0 ]; then
      ${dashboard_wrapper} coverage run dashboard/manage.py test --with-selenium --with-cherrypyliveserver
    else
      ${dashboard_wrapper} coverage run dashboard/manage.py test
  fi

  if [ -f local/local_settings.py.bak ]; then
    cp local/local_settings.py.bak local/local_settings.py
    rm local/local_settings.py.bak
  fi
  cd ..

  # get results of the openstack-dashboard tests
  DASHBOARD_RESULT=$?

  if [ $with_coverage -eq 1 ]; then
    echo "Generating coverage reports"
    ${django_wrapper} coverage combine
    ${django_wrapper} coverage xml -i --omit='/usr*,setup.py,*egg*'
    ${django_wrapper} coverage html -i --omit='/usr*,setup.py,*egg*' -d reports
    exit $(($OPENSTACK_RESULT || $DASHBOARD_RESULT))
  fi

  if [ $selenium -eq 0 ]; then
    echo "Stopping Selenium server..."
    SELENIUM_JOB=`ps -elf | grep "selenium" | grep -v grep`
    if [ $? -eq 0 ]; then
        kill `echo "${SELENIUM_JOB}" | awk '{print $4}'`
        echo "Selenium process stopped."
      else
        echo "Selenium process not found. This may require manual cleanup."
    fi
    rm -f .selenium_log
  fi
}

environment_check

if [ $just_docs -eq 1 ]; then
    run_sphinx
    exit $?
fi

if [ $just_pep8 -eq 1 ]; then
    run_pep8
    exit $?
fi

if [ $just_pylint -eq 1 ]; then
    run_pylint
    exit $?
fi

if [ $runserver -eq 1 ]; then
    run_server
    exit $?
fi

run_tests || exit

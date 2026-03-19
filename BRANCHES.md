# Branches Documentation

## Overview
This document provides comprehensive information about all branches in the ADCDEX-SUITES repository, including their purposes, current status, and merge requirements.

## Branches

| Branch Name | Purpose                          | Status           | Merge Requirements              |
|-------------|-----------------------------------|------------------|---------------------------------|
| main        | Stable release branch             | Active           | Must pass all CI tests          |
| feature/x   | Development of feature X          | In development    | Review by 1 team member         |
| bugfix/y    | Fix for bug Y                     | Ready for review  | Must pass all CI tests          |
| hotfix/z    | Immediate fix for production issue| Merged            | Quick review by a lead         |

## Notes
- For merging into `main`, ensure that the feature branch has been reviewed and all tests are passing.
- Please update this document regularly to reflect any changes to branch statuses or purposes. 

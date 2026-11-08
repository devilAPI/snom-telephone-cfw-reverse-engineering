runUpdateHelper() {
  # Load /tmp/updateHelperVariables.sh which defines the function setUpdateVariables
  source /tmp/updateHelperVariables.sh

  # Just call the defaultUpdateHelper function defined in the rescuefs rcS script.
  # If really necessary we can implement additional logic before or after the call
  # or even implement everything ourselves and don't call defaultUpdateHelper at all
  # but this should only be used as a last resort.
  defaultUpdateHelper
}

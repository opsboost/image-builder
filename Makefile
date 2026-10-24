test:
	./tests/install_bash_unit.sh
	./tests/bash_unit tests/test_composition.sh
	./tests/bash_unit tests/test_image-builder.sh

test-boot:
	./tests/bash_unit tests/test_boot_9front.sh

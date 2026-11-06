
##

TARGET=annkescan
HOSTNAME:=$(shell hostname)
CFG_SRC:=$(if $(wildcard $(TARGET).$(HOSTNAME).cfg),$(TARGET).$(HOSTNAME).cfg,$(TARGET).cfg)

# the detectors, trained on COCO (35-40 MB each, so fetched rather than in the repo):
# YOLOX-S, from the OpenCV model zoo
MODEL_YOLOX=models/yolox_s.onnx
MODEL_YOLOX_URL=https://huggingface.co/opencv/object_detection_yolox/resolve/main/object_detection_yolox_2022nov.onnx
MODEL_YOLOX_SHA256=c5c2d13e59ae883e6af3b45daea64af4833a4951c92d116ec270d9ddbe998063
# YOLO26s (Ultralytics, AGPL-3.0), as exported to ONNX by onnx-community
MODEL_YOLO26=models/yolo26s.onnx
MODEL_YOLO26_URL=https://huggingface.co/onnx-community/yolo26s-ONNX/resolve/main/onnx/model.onnx
MODEL_YOLO26_SHA256=c72bc5ad4e7f7c87666a051d0f01fc02d084688c1ca78e825031827a0590efb1
MODELS=$(MODEL_YOLOX) $(MODEL_YOLO26)

##

all: check

define fetch_model
	mkdir -p models
	curl -sSL --fail -o $@.part $(1)
	echo "$(2)  $@.part" | sha256sum -c --quiet
	mv $@.part $@
endef
$(MODEL_YOLOX):
	$(call fetch_model,$(MODEL_YOLOX_URL),$(MODEL_YOLOX_SHA256))
$(MODEL_YOLO26):
	$(call fetch_model,$(MODEL_YOLO26_URL),$(MODEL_YOLO26_SHA256))
node_modules: package.json
	npm install --no-audit --no-fund --ignore-scripts
	touch node_modules
check: $(TARGET) widewatch
	node --check $(TARGET)
	node --check widewatch
	@echo "syntax OK"
format:
	prettier --write $(TARGET) widewatch
# what clips would get, writing nothing: make test CLIP="/opt/storage/camera/side/<YYYYMMDD>/recording_<...>.mp4 ..."
# (MODEL=yolox or yolo26 for that detector rather than the one the clip's time gets)
test: $(TARGET) $(MODELS) node_modules
	./$(TARGET) $(CFG_SRC) $(if $(MODEL),--model $(MODEL)) --test $(CLIP)

.PHONY: all check format test

##

INSTALL=annkescan
DIR_INSTALL=/usr/local/bin
DIR_LIB=/usr/local/lib/annkescan
DIR_DEFAULT=/etc/default
DIR_SYSTEMD=/etc/systemd/system
define install_depend_systemd
	install -m 644 $(1).service $(DIR_SYSTEMD)/$(2).service
	systemctl daemon-reload
	systemctl enable $(2)
	systemctl start $(2) || echo "Warning: Failed to start $(2)"
endef
define install_service_systemd
	-systemctl stop $(2) 2>/dev/null || true
	install -m 644 $(1).service $(DIR_SYSTEMD)/$(2).service
	systemctl daemon-reload
	systemctl enable $(2)
	systemctl start $(2) || echo "Warning: Failed to start $(2)"
endef
# the tool, its npm dependencies and the models, in DIR_LIB; of ONNX Runtime's prebuilt binaries only
# linux/x64 is kept (the others are ~240 MB)
install_target: $(TARGET) $(MODELS) package.json package-lock.json
	install -d $(DIR_LIB)/models
	install -m 755 $(TARGET) $(DIR_LIB)/$(TARGET)
	install -m 644 package.json package-lock.json $(DIR_LIB)/
	install -m 644 $(MODELS) $(DIR_LIB)/models/
	cd $(DIR_LIB) && npm ci --omit=dev --no-audit --no-fund --ignore-scripts
	rm -rf $(DIR_LIB)/node_modules/onnxruntime-node/bin/napi-v*/darwin $(DIR_LIB)/node_modules/onnxruntime-node/bin/napi-v*/win32 \
		$(DIR_LIB)/node_modules/onnxruntime-node/bin/napi-v*/linux/arm64
	ln -sf $(DIR_LIB)/$(TARGET) $(DIR_INSTALL)/$(INSTALL)
install_default: $(CFG_SRC)
	@echo "installing config from $(CFG_SRC)"
	install -m 644 $(CFG_SRC) $(DIR_DEFAULT)/$(INSTALL)
install_storage: $(TARGET)-storage.service
	$(call install_depend_systemd,$(TARGET)-storage,$(INSTALL)-storage)
install_service: $(TARGET).service
	$(call install_service_systemd,$(TARGET),$(INSTALL))
install: check install_target install_default install_storage install_service
restart:
	systemctl restart $(INSTALL)
status:
	@systemctl --no-pager --lines=0 status $(INSTALL) || true
	@journalctl -u $(INSTALL) -n 20 --no-pager -o cat
.PHONY: install install_target install_default install_storage install_service
.PHONY: restart status

##

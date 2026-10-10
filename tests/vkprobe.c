/* vkprobe: lists the Vulkan devices the Khronos loader finds and the features vkd3d-proton and DXVK
 * hard-require from them (Runner B DX12 on KosmicKrisp).
 * Build: clang -O1 -I$(brew --prefix vulkan-headers)/include vkprobe.c \
 *          -L$(brew --prefix vulkan-loader)/lib -lvulkan -Wl,-rpath,$(brew --prefix vulkan-loader)/lib -o vkprobe
 * Run:   VK_DRIVER_FILES=<icd.json> ./vkprobe
 * Exit code: 0 when a device has every required extension and feature. */
#include <stdio.h>
#include <string.h>
#include <vulkan/vulkan.h>

static const char *exts[] = {
	"VK_KHR_swapchain", "VK_EXT_transform_feedback", "VK_EXT_depth_clip_enable",
	"VK_EXT_robustness2", "VK_EXT_custom_border_color", "VK_KHR_push_descriptor",
	"VK_EXT_shader_demote_to_helper_invocation", "VK_KHR_maintenance5",
	"VK_EXT_extended_dynamic_state2", "VK_EXT_mutable_descriptor_type", "VK_EXT_descriptor_buffer",
	"VK_EXT_image_view_min_lod", "VK_EXT_sampler_filter_minmax", "VK_KHR_portability_subset",
};

int main(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vkprobe", 1, NULL, 0, VK_API_VERSION_1_3 };
	const char *iexts[] = { "VK_KHR_portability_enumeration" };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL,
		VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR, &app, 0, NULL, 1, iexts };
	VkInstance inst;
	VkResult r = vkCreateInstance(&ici, NULL, &inst);
	if (r) { ici.flags = 0; ici.enabledExtensionCount = 0; r = vkCreateInstance(&ici, NULL, &inst); }
	if (r) { printf("vkCreateInstance: %d\n", r); return 1; }
	uint32_t n = 8, i, j, k;
	VkPhysicalDevice pd[8];
	vkEnumeratePhysicalDevices(inst, &n, pd);
	printf("devices: %u\n", n);
	int ok = 0;
	for (i = 0; i < n; i++)
	{
		VkPhysicalDeviceProperties p;
		VkPhysicalDeviceDriverProperties drv = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
		VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &drv };
		vkGetPhysicalDeviceProperties(pd[i], &p);
		vkGetPhysicalDeviceProperties2(pd[i], &p2);
		printf("device %u: %s, api %u.%u.%u, driver %s %s\n", i, p.deviceName, VK_API_VERSION_MAJOR(p.apiVersion),
		       VK_API_VERSION_MINOR(p.apiVersion), VK_API_VERSION_PATCH(p.apiVersion), drv.driverName, drv.driverInfo);
		uint32_t ne = 0;
		vkEnumerateDeviceExtensionProperties(pd[i], NULL, &ne, NULL);
		VkExtensionProperties ep[1024];
		if (ne > 1024) ne = 1024;
		vkEnumerateDeviceExtensionProperties(pd[i], NULL, &ne, ep);
		printf("  extensions: %u\n", ne);
		int missing = 0;
		for (j = 0; j < sizeof(exts) / sizeof(*exts); j++)
		{
			int have = 0;
			for (k = 0; k < ne; k++) if (!strcmp(ep[k].extensionName, exts[j])) have = 1;
			printf("  %-45s %s\n", exts[j], have ? "yes" : "no");
		}
		VkPhysicalDeviceTransformFeedbackFeaturesEXT xfb = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT };
		VkPhysicalDeviceRobustness2FeaturesEXT rob = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT, &xfb };
		VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &rob };
		VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v12 };
		vkGetPhysicalDeviceFeatures2(pd[i], &f2);
#define F(name, v) do { printf("  %-45s %d\n", #name, (int)(v)); if (!(v)) missing++; } while (0)
		F(transformFeedback, xfb.transformFeedback);
		F(geometryShader, f2.features.geometryShader);
		F(fillModeNonSolid, f2.features.fillModeNonSolid);
		F(sparseBinding, f2.features.sparseBinding);
		F(sparseResidencyImage2D, f2.features.sparseResidencyImage2D);
		F(shaderResourceResidency, f2.features.shaderResourceResidency);
		F(timelineSemaphore, v12.timelineSemaphore);
		F(bufferDeviceAddress, v12.bufferDeviceAddress);
		F(descriptorIndexing, v12.descriptorIndexing);
		F(nullDescriptor, rob.nullDescriptor);
#undef F
		printf("  required features missing: %d\n", missing);
		if (!missing) ok = 1;
	}
	vkDestroyInstance(inst, NULL);
	return ok ? 0 : 1;
}

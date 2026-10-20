-- p4: UI sprite shader for Anomaly's "hud\default" l_shader.
-- Semantics of the monolith DX hud\default: vertex-color * texture, straight
-- alpha blending, no depth, no fog. (Deliberately NOT font2: that one flips
-- alpha for the inverted font atlas and drops vertex color, which renders UI
-- sprites as white silhouettes.)
-- VS must be stub_notransform_t: the DX11-style UI pipeline pre-transforms
-- vertices to screen space on the CPU; stub_default.vs would apply m_WVP a
-- second time and project every sprite off-screen (invisible-menu bug).
function normal		(shader, t_base, t_second, t_detail)
	shader:begin	("stub_notransform_t","stub_default")
			: fog		(false)
			: zb 		(false,false)
			: blend		(true,blend.srcalpha,blend.invsrcalpha)
	shader:sampler	("s_base")	: texture(t_base)	: clamp() : f_linear ()
end

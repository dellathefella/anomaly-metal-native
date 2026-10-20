-- p4: UI sprite shader for Anomaly's "hud\default" l_shader.
-- Semantics of the monolith DX hud\default: vertex-color * texture, straight
-- alpha blending, no depth, no fog. (Deliberately NOT font2: that one flips
-- alpha for the inverted font atlas and drops vertex color, which renders UI
-- sprites as white silhouettes.)
function normal		(shader, t_base, t_second, t_detail)
	shader:begin	("stub_default","stub_default")
			: fog		(false)
			: zb 		(false,false)
			: blend		(true,blend.srcalpha,blend.invsrcalpha)
	shader:sampler	("s_base")	: texture(t_base)	: clamp() : f_linear ()
end

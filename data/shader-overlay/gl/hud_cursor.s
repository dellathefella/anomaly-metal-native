-- p4: cursor sprite for Anomaly's "hud\cursor" l_shader. Same sprite
-- semantics as hud_default (color * texture, straight alpha).
function normal		(shader, t_base, t_second, t_detail)
	shader:begin	("stub_default","stub_default")
			: fog		(false)
			: zb 		(false,false)
			: blend		(true,blend.srcalpha,blend.invsrcalpha)
	shader:sampler	("s_base")	: texture(t_base)	: clamp() : f_linear ()
end

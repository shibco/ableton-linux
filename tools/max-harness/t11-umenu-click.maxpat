{
	"patcher" : 	{
		"fileversion" : 1,
		"appversion" : 		{
			"major" : 9,
			"minor" : 1,
			"revision" : 4,
			"architecture" : "x64",
			"modernui" : 1
		},
		"classnamespace" : "box",
		"rect" : [ 300.0, 300.0, 500.0, 400.0 ],
		"boxes" : [ 			{
				"box" : 				{
					"id" : "obj-1",
					"maxclass" : "newobj",
					"text" : "loadbang",
					"numinlets" : 0,
					"numoutlets" : 1,
					"outlettype" : [ "bang" ],
					"patching_rect" : [ 300.0, 30.0, 60.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-2",
					"maxclass" : "message",
					"text" : "HARNESS t11 umenu loaded",
					"numinlets" : 2,
					"numoutlets" : 1,
					"outlettype" : [ "" ],
					"patching_rect" : [ 300.0, 70.0, 170.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-3",
					"maxclass" : "newobj",
					"text" : "print HARNESS",
					"numinlets" : 1,
					"numoutlets" : 0,
					"patching_rect" : [ 300.0, 110.0, 90.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-4",
					"maxclass" : "umenu",
					"items" : [ "alpha", ",", "beta", ",", "gamma", ",", "delta", ",", "epsilon" ],
					"numinlets" : 1,
					"numoutlets" : 3,
					"outlettype" : [ "int", "", "" ],
					"parameter_enable" : 0,
					"patching_rect" : [ 40.0, 60.0, 180.0, 30.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-5",
					"maxclass" : "newobj",
					"text" : "print UMENUSEL",
					"numinlets" : 1,
					"numoutlets" : 0,
					"patching_rect" : [ 40.0, 120.0, 100.0, 22.0 ]
				}
			}
 ],
		"lines" : [ 			{
				"patchline" : 				{
					"source" : [ "obj-1", 0 ],
					"destination" : [ "obj-2", 0 ]
				}
			}
, 			{
				"patchline" : 				{
					"source" : [ "obj-2", 0 ],
					"destination" : [ "obj-3", 0 ]
				}
			}
, 			{
				"patchline" : 				{
					"source" : [ "obj-4", 0 ],
					"destination" : [ "obj-5", 0 ]
				}
			}
 ]
	}
}
